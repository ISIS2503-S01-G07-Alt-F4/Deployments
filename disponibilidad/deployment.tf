# Infraestructura para requerimiento de disponibilidad
#
# Elementos a desplegar en AWS:
# 1. Grupos de seguridad:
#    - traffic-django (puerto 8080)
#    - traffic-cb (puertos 8000 y 8001)
#    - traffic-db (puerto 5432)
#    - traffic-ssh (puerto 22)
#
# 2. Instancias EC2:
#    - kong
#    - db (PostgreSQL instalado y configurado)
#    - cbd-app-a (app instalada y migraciones aplicadas)
#    - cbd-app-b (app instalada y migraciones aplicadas)
#    - cbd-app-c (app instalada y migraciones aplicadas)
# ******************************************************************


# Variable. Define la región de AWS donde se desplegará la infraestructura.
variable "region" {
    description = "AWS region for deployment"
    type        = string
    default     = "us-east-1"
}

variable "project_prefix" {
    description = "Prefix used for naming AWS resources"
    type        = string
    default     = "disp"
}

# Variable. Define el tipo de instancia EC2 a usar para las máquinas virtuales.
variable "instance_type" {
    description = "EC2 instance type for application hosts"
    type        = string
    default     = "t2.nano"
}

# Proveedor. Define el proveedor de infraestructura (AWS) y la región.
provider "aws" {
    region = var.region
}

locals {
    project_name = "disponibilidad-provesi"
    repository = "https://github.com/ISIS2503-S01-G07-Alt-F4/Sprint-2.git"

    common_tags = {
        Project = local.project_name
        ManagedBy = "Terraform"
    }
}

# Data Source. Busca la AMI más reciente de Ubuntu 24.04 usando los filtros especificados.
data "aws_ami" "ubuntu" {
    most_recent = true
    owners      = ["099720109477"]

    filter {
        name   = "name"
        values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
    }

    filter {
        name   = "virtualization-type"
        values = ["hvm"]
    }
}

resource "aws_security_group" "traffic_django" {
    name        = "${var.project_prefix}-traffic-django"
    description = "Allow traffic on port 8080"

    ingress {
        from_port   = 8080
        to_port     = 8080
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = merge(local.common_tags, {
        Name = "${var.project_prefix}-traffic-services"
    })
}

resource "aws_security_group" "traffic_cb" {
    name        = "${var.project_prefix}-traffic-cb"
    description = "Expose Kong circuit breaker ports"

    ingress {
        description = "Kong traffic"
        from_port   = 8000
        to_port     = 8001
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = merge(local.common_tags, {
        Name = "${var.project_prefix}-traffic-cb"
    })
}

resource "aws_security_group" "traffic_db" {
    name        = "${var.project_prefix}-traffic-db"
    description = "Allow PostgreSQL access"

    ingress {
        description = "Traffic from anywhere to DB"
        from_port   = 5432
        to_port     = 5432
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = merge(local.common_tags, {
        Name = "${var.project_prefix}-traffic-db"
    })
}

# Recurso. Define el grupo de seguridad para el tráfico SSH (22) y permite todo el tráfico saliente.
resource "aws_security_group" "traffic_ssh" {
    name        = "${var.project_prefix}-traffic-ssh"
    description = "Allow SSH access"

    ingress {
        description = "SSH access from anywhere"
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        description = "Allow all outbound traffic"
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = merge(local.common_tags, {
        Name = "${var.project_prefix}-traffic-ssh"
    })
}

resource "aws_instance" "database" {
    ami = data.aws_ami.ubuntu.id
    instance_type = var.instance_type
    associate_public_ip_address = true
    vpc_security_group_ids = [aws_security_group.traffic_db.id, aws_security_group.traffic_ssh.id]

    user_data = <<-EOT
                #!/bin/bash

                sudo apt-get update -y
                sudo apt-get install -y postgresql postgresql-contrib

                sudo -u postgres psql -c "CREATE USER provesi_user WITH PASSWORD 'Alt-f4';"
                sudo -u postgres createdb -O provesi_user provesi_db
                echo "host all all 0.0.0.0/0 trust" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
                echo "listen_addresses='*'" | sudo tee -a /etc/postgresql/16/main/postgresql.conf
                echo "max_connections=2000" | sudo tee -a /etc/postgresql/16/main/postgresql.conf
                sudo service postgresql restart
                EOT

    tags = merge(local.common_tags, {
        Name = "${var.project_prefix}-db"
        Role = "database"
    })
}

resource "aws_instance" "apps" {
    for_each = toset(["a", "b", "c"])

    ami = data.aws_ami.ubuntu.id
    instance_type = var.instance_type
    associate_public_ip_address = true
    vpc_security_group_ids = [
        aws_security_group.traffic_django.id,
        aws_security_group.traffic_ssh.id
    ]

    user_data = <<-EOT
                #!/bin/bash
                sudo export DATABASE_HOST=${aws_instance.database.private_ip}
                echo "DATABASE_HOST=${aws_instance.database.private_ip}" | sudo tee -a /etc/environment

                sudo apt-get update -y
                sudo apt-get install -y python3-pip git build-essential libpq-dev python3-dev

                mkdir -p /project
                cd /project

                if [ ! -d SPRINT-2 ]; then
                    git clone ${local.repository}
                fi

                cd Sprint-2
                sudo pip3 install --upgrade pip --break-system-packages
                pip3 install -r requirements.txt --break-system-packages

                sudo nohup python3 manage.py runserver 0.0.0.0:8080 &
                EOT
    tags = merge(local.common_tags, {
        Name = "${var.project_prefix}-app-${each.key}"
        Role = "application-server"
    })
}

resource "aws_instance" "kong" {
    ami = data.aws_ami.ubuntu.id
    instance_type = var.instance_type
    associate_public_ip_address = true
    vpc_security_group_ids = [
        aws_security_group.traffic_cb.id,
        aws_security_group.traffic_ssh.id
    ]

    user_data = <<-EOF
                #!/bin/bash

                sudo apt-get update
                sudo apt-get install ca-certificates curl gnupg lsb-release -y
                sudo mkdir -p /etc/apt/keyrings

                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                echo \
                  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                
                sudo apt-get update
                sudo apt-get install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
                sudo usermod -aG docker $USER
                newgrp docker
                
                # Crear el archivo kong.yml en /home/ubuntu/kong.yml con las IP privadas de las apps
                cat > /home/ubuntu/kong.yml <<KONG
                _format_version: "2.1"

                services:
                  - host: provesi_upstream
                    name: provesi_service
                    protocol: http
                    routes:
                      - name: provesi_route
                        paths:
                          - /
                        strip_path: false 

                upstreams:
                  - name: provesi_upstream
                    targets:
                      - target: ${aws_instance.apps["a"].private_ip}:8080
                        weight: 100
                      - target: ${aws_instance.apps["b"].private_ip}:8080
                        weight: 100
                      - target: ${aws_instance.apps["c"].private_ip}:8080
                        weight: 100
                    healthchecks:
                      threshold: 2
                      active:
                        http_path: /health/
                        timeout: 10
                        healthy:
                          interval: 10
                          successes: 4
                        unhealthy:
                          interval: 5
                          tcp_failures: 1
                KONG

                sudo docker network create kong-net
                EOF

    tags = merge(local.common_tags, {
        Name = "${var.project_prefix}-kong"
        Role = "circuit-breaker"
    })
}

# Salida. Muestra la dirección IP pública de la instancia de Kong (Circuit Breaker).
output "kong_public_ip" {
  description = "Public IP address for the Kong circuit breaker instance"
  value       = aws_instance.kong.public_ip
}

# Salida. Muestra las direcciones IP públicas de las instancias de la aplicación.
output "apps_public_ips" {
  description = "Public IP addresses for the alarms service instances"
  value       = { for id, instance in aws_instance.apps : id => instance.public_ip }
}

# Salida. Muestra las direcciones IP privadas de las instancias de la aplicación.
output "apps_private_ips" {
  description = "Private IP addresses for the alarms service instances"
  value       = { for id, instance in aws_instance.apps : id => instance.private_ip }
}

# Salida. Muestra la dirección IP privada de la instancia de la base de datos PostgreSQL.
output "database_private_ip" {
  description = "Private IP address for the PostgreSQL database instance"
  value       = aws_instance.database.private_ip
}
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

variable "instance_type" {
  description = "EC2 instance type for application hosts"
  type        = string
  default     = "t2.nano"
}

provider "aws" {
  region = var.region
}

locals {
  project_name  = "disponibilidad-provesi"
  repository    = "https://github.com/ISIS2503-S01-G07-Alt-F4/Sprint-2.git"
  alert_email   = "js.avilan@uniandes.edu.co" # ← correo donde llegan las notificaciones

  common_tags = {
    Project   = local.project_name
    ManagedBy = "Terraform"
  }
}

# AMI Ubuntu 24.04
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

# VPC por defecto (para restringir el puerto 8001)
data "aws_vpc" "default" {
  default = true
}

###############################################################################
# Security Groups
###############################################################################

# Tráfico de apps — solo desde Kong
resource "aws_security_group" "traffic_django" {
  name        = "${var.project_prefix}-traffic-django"
  description = "Allow traffic to app instances only from Kong (traffic-cb)."

  ingress {
    description     = "App port from Kong"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.traffic_cb.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-django" })
}

# Kong (circuit breaker / load balancer)
resource "aws_security_group" "traffic_cb" {
  name        = "${var.project_prefix}-traffic-cb"
  description = "Expose Kong circuit breaker ports"

  # Proxy público
  ingress {
    description = "Kong proxy (public)"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Admin interno
  ingress {
    description = "Kong admin (internal only)"
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-cb" })
}

# PostgreSQL solo accesible desde apps
resource "aws_security_group" "traffic_db" {
  name        = "${var.project_prefix}-traffic-db"
  description = "Allow PostgreSQL access from app servers"

  ingress {
    description     = "Postgres from app servers"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.traffic_django.id]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-db" })
}

# SSH (restringir IPs en producción)
resource "aws_security_group" "traffic_ssh" {
  name        = "${var.project_prefix}-traffic-ssh"
  description = "Allow SSH access"

  ingress {
    description = "SSH from anywhere (adjust in prod)"
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

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-ssh" })
}

###############################################################################
# Instancias
###############################################################################

# Base de datos
resource "aws_instance" "database" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_db.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
              #!/bin/bash
              apt-get update -y
              apt-get install -y postgresql postgresql-contrib
              sudo -u postgres psql -c "CREATE USER provesi_user WITH PASSWORD 'Alt-f4';"
              sudo -u postgres createdb -O provesi_user provesi_db
              echo "host all all 0.0.0.0/0 trust" | tee -a /etc/postgresql/16/main/pg_hba.conf
              echo "listen_addresses='*'" | tee -a /etc/postgresql/16/main/postgresql.conf
              echo "max_connections=2000" | tee -a /etc/postgresql/16/main/postgresql.conf
              service postgresql restart
              EOT

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-db", Role = "database" })
}

# Apps
resource "aws_instance" "apps" {
  for_each = toset(["a", "b", "c"])

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
              #!/bin/bash
              export DATABASE_HOST=${aws_instance.database.private_ip}
              echo "DATABASE_HOST=${aws_instance.database.private_ip}" | tee -a /etc/environment

              apt-get update -y
              apt-get install -y python3-pip git build-essential libpq-dev python3-dev

              mkdir -p /project && cd /project
              git clone ${local.repository} || true
              cd Sprint-2
              pip3 install --upgrade pip --break-system-packages
              pip3 install -r requirements.txt --break-system-packages

              export ALERT_EMAIL="${local.alert_email}"
              echo "ALERT_EMAIL=${local.alert_email}" | tee -a /etc/environment

              python3 manage.py runserver 0.0.0.0:8080
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-app-${each.key}",
    Role = "application-server"
  })
}

# Kong (circuit breaker / load balancer)
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_cb.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y ca-certificates curl gnupg lsb-release docker-ce docker-ce-cli containerd.io docker-compose-plugin python3 python3-pip git

              # Crear kong.yml con IPs privadas
              cat > /home/ubuntu/kong.yml <<KONG
              _format_version: "2.1"
              services:
                - host: provesi_upstream
                  name: provesi_service
                  protocol: http
                  routes:
                    - name: provesi_route
                      paths: ["/"]
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

              # Instalar monitor_kong
              cd /home/ubuntu
              git clone ${local.repository} || true
              cd Sprint-2
              pip3 install -r requirements.txt --break-system-packages

              export ALERT_EMAIL="${local.alert_email}"
              echo "ALERT_EMAIL=${local.alert_email}" | tee -a /etc/environment

              cat > /home/ubuntu/run_monitor.sh <<'RUNMON'
              #!/bin/bash
              cd /home/ubuntu/Sprint-2
              export KONG_ADMIN_URL="http://127.0.0.1:8001"
              export KONG_UPSTREAM="provesi_upstream"
              export ALERT_EMAIL="${local.alert_email}"
              python3 manage.py monitor_kong --kong-admin "$KONG_ADMIN_URL" --upstream "$KONG_UPSTREAM" --interval 30 --email "$ALERT_EMAIL"
              RUNMON
              chmod +x /home/ubuntu/run_monitor.sh

              cat > /etc/systemd/system/monitor-kong.service <<'SERVICE'
              [Unit]
              Description=Kong upstream monitor (Django management command)
              After=network.target

              [Service]
              Type=simple
              User=ubuntu
              ExecStart=/home/ubuntu/run_monitor.sh
              Restart=always
              RestartSec=10
              Environment=PYTHONUNBUFFERED=1

              [Install]
              WantedBy=multi-user.target
              SERVICE

              systemctl daemon-reload
              systemctl enable --now monitor-kong.service
              EOF

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-kong",
    Role = "circuit-breaker"
  })
}

###############################################################################
# Outputs
###############################################################################

output "kong_public_ip" {
  description = "Public IP for Kong (load balancer)"
  value       = aws_instance.kong.public_ip
}

output "apps_public_ips" {
  description = "Public IPs for Django app instances"
  value       = { for id, inst in aws_instance.apps : id => inst.public_ip }
}

output "apps_private_ips" {
  description = "Private IPs for Django app instances"
  value       = { for id, inst in aws_instance.apps : id => inst.private_ip }
}

output "database_private_ip" {
  description = "Private IP for the PostgreSQL database"
  value       = aws_instance.database.private_ip
}    

#################################################################

# Grupo de seguridad para monitoreo
resource "aws_security_group" "traffic_monitoring" {
name = "${var.project_prefix}-traffic-monitoring"
description = "Allow incoming traffic to monitoring instance (SSH + HTTP(9090))"


ingress {
description = "SSH from anywhere (adjust in prod)"
from_port = 22
to_port = 22
protocol = "tcp"
cidr_blocks = ["0.0.0.0/0"]
}


ingress {
description = "Monitoring HTTP (port 9090)"
from_port = 9090
to_port = 9090
protocol = "tcp"
cidr_blocks = ["0.0.0.0/0"]
}


egress {
description = "Allow all outbound traffic"
from_port = 0
to_port = 0
protocol = "-1"
cidr_blocks = ["0.0.0.0/0"]
}


tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-monitoring" })
}


# Instancia de monitoreo
resource "aws_instance" "monitoring" {
ami = data.aws_ami.ubuntu.id
instance_type = var.instance_type
associate_public_ip_address = true
vpc_security_group_ids = [aws_security_group.traffic_ssh.id, aws_security_group.traffic_monitoring.id]


user_data = <<-EOT
#!/bin/bash
set -e
apt-get update -y
apt-get install -y python3-pip git build-essential python3-dev || true


# Directorio del proyecto
mkdir -p /project && cd /project


# Clonar el repositorio principal (se reusa la variable local.repository usada por las apps)
git clone ${local.repository} || true


# Intentar entrar a la carpeta Sprint-2 si existe (mismo layout que las apps)
if [ -d "Sprint-2" ]; then
cd Sprint-2
else
# si el repositorio tiene otro layout, intentar ejecutar en la raíz
cd $(ls -1 | head -n 1) || true
fi


# Instalar dependencias si hay requirements.txt
if [ -f requirements.txt ]; then
pip3 install --upgrade pip --break-system-packages || true
pip3 install -r requirements.txt --break-system-packages || true
fi


# Crear servicio systemd para ejecutar monitor.py si existe
if [ -f monitor.py ]; then
cat > /etc/systemd/system/monitoring.service <<SERVICE
[Unit]
Description=Monitoring Service for project
After=network.target


[Service]
Type=simple
WorkingDirectory=/project/Sprint-2
ExecStart=/usr/bin/python3 /project/Sprint-2/monitor.py
Restart=on-failure


[Install]
WantedBy=multi-user.target
SERVICE


systemctl daemon-reload
systemctl enable monitoring.service
systemctl start monitoring.service
else
# Si no hay monitor.py, intentar levantar una app simple en 9090 si manage.py existe
if [ -f manage.py ]; then
nohup python3 manage.py runserver 0.0.0.0:9090 &>/var/log/monitoring.log &
fi
fi
EOT


tags = merge(local.common_tags, { Name = "${var.project_prefix}-monitoring", Role = "monitoring" })
}


}

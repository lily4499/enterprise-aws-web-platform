packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "ami_name" {
  type = string
}

source "amazon-ebs" "ubuntu" {
  region          = var.aws_region
  instance_type   = "t3.micro"
  ssh_username    = "ubuntu"
  ami_name        = var.ami_name
  ami_description = "Enterprise web AMI with Nginx + app deploy service"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }
}

build {
  name    = "enterprise-web-ami"
  sources = ["source.amazon-ebs.ubuntu"]

  # Install packages + AWS CLI v2 (official)
  provisioner "shell" {
    inline = [
      #"set -euo pipefail",
      "export DEBIAN_FRONTEND=noninteractive",

      "sudo apt-get update",
      "sudo apt-get install -y nginx curl unzip ca-certificates",

      # Install AWS CLI v2
      "curl -sS 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip",
      "unzip -q /tmp/awscliv2.zip -d /tmp",
      "sudo /tmp/aws/install --update",
      "aws --version",

      "sudo systemctl enable nginx"
    ]
  }

  # Copy configs/scripts
  provisioner "file" {
    source      = "files/nginx.conf"
    destination = "/tmp/nginx.conf"
  }

  provisioner "file" {
    source      = "files/app-deploy.sh"
    destination = "/tmp/app-deploy.sh"
  }

  provisioner "file" {
    source      = "files/app-deploy.service"
    destination = "/tmp/app-deploy.service"
  }

  # Configure nginx + systemd deploy service + safe defaults
  provisioner "shell" {
    inline = [
      #"set -euo pipefail",

      # Web root exists + has default content so '/' never returns 403 on fresh instance
      "sudo mkdir -p /var/www/html",
      "echo '<h1>✅ AMI baked successfully</h1>' | sudo tee /var/www/html/index.html >/dev/null",
      "echo 'ok' | sudo tee /var/www/html/health >/dev/null",

      # Permissions prevent 403
      "sudo chown -R www-data:www-data /var/www/html",
      "sudo chmod -R 755 /var/www/html",
      "sudo chmod 644 /var/www/html/index.html /var/www/html/health",

      # Apply nginx config
      "sudo mv /tmp/nginx.conf /etc/nginx/sites-available/default",
      "sudo nginx -t",
      "sudo systemctl restart nginx",

      # Deploy service setup
      "sudo mkdir -p /etc/app",
      "sudo mv /tmp/app-deploy.sh /usr/local/bin/app-deploy.sh",
      "sudo chmod +x /usr/local/bin/app-deploy.sh",
      "sudo mv /tmp/app-deploy.service /etc/systemd/system/app-deploy.service",

      # Placeholder key (Ansible/Jenkins will update)
      "echo 'releases/app-1.tar.gz' | sudo tee /etc/app/artifact_key >/dev/null",

      # IMPORTANT: Do NOT set bucket name here (it is environment-specific)
      # Ansible will write /etc/app/env with ARTIFACT_BUCKET=...
      "sudo rm -f /etc/app/env || true",

      "sudo systemctl daemon-reload",
      "sudo systemctl enable app-deploy.service",

      # Bake validation
      "curl -s -I http://127.0.0.1/ | head -n 1",
      "curl -s http://127.0.0.1/health || true"
    ]
  }
}

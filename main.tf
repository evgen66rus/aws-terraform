# module "vpc" {
#   source = "terraform-aws-modules/vpc/aws"

#   name = "stage"
#   cidr = "10.0.0.0/16"

#   azs             = ["us-east-1a", "us-east-1b"]
#   private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
#   public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

#   enable_nat_gateway = false
#   enable_vpn_gateway = false
#   enable_dns_hostnames = true

#   tags = {
#     Terraform = "true"
#     Environment = "stage"
#   }
# }

variable "vpc" {
  type = string
  default = "vpc-0da21b70"
}
variable "private_subnets" {
  type = list(string)
  default = ["172.31.64.0/20", "172.31.80.0/20", "172.31.32.0/20", "172.31.16.0/20", "172.31.48.0/20", "172.31.0.0/20"]
}
variable "subnet_ids" {
  type = list(string)
  default = ["subnet-69c4e367", "subnet-6f006b4e", "subnet-70fe902f", "subnet-a7a598ea", "subnet-7de5554c", "subnet-c6b7daa0"]
}

module "web_alb_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"

  name        = "web-alb"
  description = "Security group for web-server with HTTP ports open within VPC"
  vpc_id      = var.vpc

  ingress_cidr_blocks = ["0.0.0.0/0"]
}

module "web_ec2_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"
  name        = "web-ec2"
  description = "Security group for web-server with HTTP ports open within VPC"
  vpc_id      = var.vpc
  ingress_cidr_blocks = ["172.31.0.0/16"]
  computed_ingress_with_source_security_group_id = [
    {
      rule = "http-80-tcp"
      source_security_group_id = module.web_alb_sg.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1
}

module "mysql-sg" {
  source = "terraform-aws-modules/security-group/aws//modules/mysql"
  name = "mysql-sg"
  description = "Security group for mysql access from ec2"
  vpc_id = var.vpc
  ingress_cidr_blocks = ["172.31.0.0/16"]
  computed_ingress_with_source_security_group_id = [
    {
      rule = "mysql"
      source_security_group_id = module.web_ec2_sg.security_group_id
    }
  ]
}

module "ssh_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/ssh"
  name        = "ssh-ec2"
  description = "Security group for SSH access"
  vpc_id      = var.vpc
  ingress_cidr_blocks = ["0.0.0.0/0"]
}

module "efs_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "efs_sg"
  description = "Security group for access EFS"
  vpc_id      = var.vpc

  computed_ingress_with_source_security_group_id      = [
    {
      rule = "nfs-tcp"
      source_security_group_id = module.efs_instance_sg.security_group_id
    }
  ]
}

module "efs_instance_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "efs_instance_sg"
  description = "Security group for access EFS"
  vpc_id      = var.vpc

  computed_egress_with_source_security_group_id      = [
    {
      rule = "nfs-tcp"
      source_security_group_id = module.efs_sg.security_group_id
    }
  ]
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  identifier = "demodb"
  engine            = "mysql"
  engine_version    = "5.7.19"
  instance_class    = "db.t2.micro"
  allocated_storage = 5
  name     = "wordpress"
  username = "user"
  password = "YourPwdShouldBeLongAndSecure!"
  port     = "3306"
  iam_database_authentication_enabled = true
  vpc_security_group_ids = ["${module.mysql-sg.security_group_id}"]
  subnet_ids = var.subnet_ids
  family = "mysql5.7"
  major_engine_version = "5.7"
  skip_final_snapshot = true
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"

    values = [
      "amzn-ami-hvm-*-x86_64-gp2",
    ]
  }
}


resource "aws_iam_instance_profile" "ssm" {
  name = "complete-asg-test"
  role = aws_iam_role.ssm.name
}

resource "aws_iam_role" "ssm" {
  name = "complete-asg-test"

  assume_role_policy = <<-EOT
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Effect": "Allow",
        "Sid": ""
      }
    ]
  }
  EOT
}


module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"

  # Autoscaling group
  name = "test-asg"

  min_size                  = 2
  max_size                  = 2
  desired_capacity          = 2
  health_check_type         = "EC2"
  vpc_zone_identifier       = var.subnet_ids

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }

  target_group_arns = module.alb.target_group_arns

  # Launch template
  lc_name                = "test-asg"
  description            = "Launch template example"
  update_default_version = true

  use_lc    = true
  create_lc = true

  image_id          = "ami-0d5eff06f840b45e9"
  instance_type     = "t2.micro"
  user_data = <<-EOT
  #!/bin/bash
  yum update -y
  yum install -y amazon-efs-utils
  yum install -y nfs-utils
  file_system_id_1=fs-8f981c3b
  mkdir -p /var/www/html
  efs_mount_point_1=/var/www/html
  mount -t efs -o tls,accesspoint=fsap-0e264f54917e8c13a fs-8f981c3b:/ /var/www/html
  yum install -y httpd
  amazon-linux-extras install -y php7.3
  systemctl start httpd
  systemctl enable httpd
  cd /home/ec2-user/
  wget https://wordpress.org/latest.tar.gz
  tar -xzf latest.tar.gz
  cp -r wordpress/* /var/www/html/
  yum install -y git
  git clone https://github.com/evgen66rus/test-aws-task.git
  cp -r test-aws-task/wp-config.php /var/www/html/
  cp -r test-aws-task/httpd.conf /etc/httpd/conf/httpd.conf
  chmod -R 755 /var/www/html/
  printf "define( \'DB_HOST\', \'\${module.rds.db_instance_endpoint}\' );\n" >> /var/www/html/wp-config.php
  systemctl restart httpd
  EOT
  ebs_optimized     = false
  enable_monitoring = false
  key_name          = "us-east-1"
  security_groups = [module.web_ec2_sg.security_group_id, module.ssh_sg.security_group_id, "sg-0dbbc1a00a0b7a1b6"]

  block_device_mappings = [
    {
      # Root volume
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = false
        volume_size           = 8
        volume_type           = "gp2"
      }
      }
  ]

  network_interfaces = [
    {
      delete_on_termination = true
      description           = "eth0"
      device_index          = 0
      security_groups       = [module.web_ec2_sg.security_group_id, module.ssh_sg.security_group_id, "sg-0dbbc1a00a0b7a1b6"]
    }
  ]

  placement = {
    availability_zone = "any"
  }

  tag_specifications = [
    {
      resource_type = "instance"
      tags          = { WhatAmI = "Instance" }
    },
    {
      resource_type = "volume"
      tags          = { WhatAmI = "Volume" }
    }
  ]

  tags = [
    {
      key                 = "Environment"
      value               = "stage"
      propagate_at_launch = true
    },
    {
      key                 = "Name"
      value               = "Test-asg"
      propagate_at_launch = true
    },
  ]

  tags_as_map = {
    extra_tag1 = "extra_value1"
    extra_tag2 = "extra_value2"
  }
}


module "alb" {
  source  = "terraform-aws-modules/alb/aws"

  name = "test-alb"

  load_balancer_type = "application"

  vpc_id             = var.vpc
  subnets            = var.subnet_ids
  security_groups    = [module.web_alb_sg.security_group_id]

  target_groups = [
    {
      name_prefix      = "pref-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = {
    Environment = "Test"
  }
}
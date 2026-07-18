terraform {
  backend "s3" {
    region = "ap-southeast-2"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
  }

  required_version = ">= 1.2"
}

provider "aws" {
  region = "ap-southeast-2"
}

resource "aws_instance" "kraken" {
  ami           = data.aws_ami.ubuntu.id
  iam_instance_profile = aws_iam_instance_profile.ec2.name
  instance_type = "r7i.4xlarge"

  root_block_device {
    volume_size = 150
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  owners = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

### Session Manager so w can connecting using SSH via CLI.
resource "aws_iam_role" "ec2" {
  name = "kraken-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "kraken-ec2"
  role = aws_iam_role.ec2.name
}

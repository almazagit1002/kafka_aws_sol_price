provider "aws" {
  region = "us-west-2"
}

# Fetch your current public IP
data "http" "my_ip" {
  url = "https://api.ipify.org?format=text"
}

resource "tls_private_key" "kafka_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2_key" {
  key_name   = "my-ec2-key"
  public_key = tls_private_key.kafka_key.public_key_openssh
}

resource "aws_s3_bucket" "data_bucket" {
  bucket = "my-kafka-data-bucket-sol-ale"
}

resource "aws_iam_role" "glue_role" {
  name = "glue_crawler_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [ {
      Effect    = "Allow",
      Principal = { Service = "glue.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy_attachment" "glue_s3_access" {
  name       = "glue_s3_access"
  roles      = [aws_iam_role.glue_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_glue_crawler" "s3_crawler" {
  name          = "s3-kafka-crawler"
  database_name = "kafka_data_db"
  role          = aws_iam_role.glue_role.arn
  s3_target {
    path = "s3://${aws_s3_bucket.data_bucket.bucket}/"
  }
}

resource "aws_iam_role" "ec2_role" {
  name = "ec2_kafka_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_kafka_profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_security_group" "ec2_sg" {
  name_prefix = "ec2-kafka-sg"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [format("%s/32", chomp(data.http.my_ip.body))] 
  }

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Adjust as needed
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "kafka_ec2" {
  ami             = "ami-0a897ba00eaed7398"  # Amazon Linux 2023 (x86)
  instance_type   = "t2.micro"  # Change to "t3.small" if needed
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  security_groups      = [aws_security_group.ec2_sg.name]
  key_name        = aws_key_pair.ec2_key.key_name  # Use the key pair created
  user_data            = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install java-1.8.0 -y
              wget https://downloads.apache.org/kafka/3.1.0/kafka_2.13-3.1.0.tgz
              tar -xvzf kafka_2.13-3.1.0.tgz
              EOF
}

resource "aws_athena_database" "kafka_db" {
  name   = "kafka_data_db"
  bucket = aws_s3_bucket.data_bucket.bucket
}
output "private_key_pem" {
  value     = tls_private_key.kafka_key.private_key_pem
  sensitive = true
}
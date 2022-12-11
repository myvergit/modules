
resource "aws_launch_configuration" "example" {
    image_id            = "ami-0fb653ca2d3203ac1"
    instance_type       = var.instance_type
    security_groups     = [aws_security_group.instance.id]

    # Render the User Data script as a template
    user_data = templatefile("${path.module}/user-data.sh", {
        server_port = var.server_port
        db_address  = data.terraform_remote_state.db.outputs.address
        db_port     = data.terraform_remote_state.db.outputs.port
    })


     # Required when using a launch configuration with an auto scaling group.
     lifecycle {
        create_before_destroy = true
     }       
}

resource "aws_security_group" "instance" {
    name = "${var.cluster_name}-instance" 
}

resource "aws_security_group_rule" "allow_server_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instance.id

  from_port   = var.server_port
  to_port     = var.server_port
  protocol    = local.tcp_protocol
  cidr_blocks = local.all_ips
}


resource "aws_autoscaling_group" "example" {
    launch_configuration    = aws_launch_configuration.example.name
    
    # Pull the subnets IDs out of aws_subnets data source and tell your ASG to use those subnets
    vpc_zone_identifier     = data.aws_subnets.default.ids

    target_group_arns   = [aws_lb_target_group.asg.arn]
    # Update health_check_type to "ELB", default is "EC2"
    health_check_type        = "ELB"

    min_size = var.min_size
    max_size = var.max_size

    tag {
        key                 = "Name"
        value               = var.cluster_name
        propagate_at_launch = true
    }
}



# Create the ALB using the aws_lb resource
resource "aws_lb" "example" {
    name                = var.cluster_name
    load_balancer_type  = "application"
    subnets             = data.aws_subnets.default.ids
    # Tell the ALB to use security group via security_groups argument
    security_groups     = [aws_security_group.alb.id]
}


# Define a listener for this ALB using the aws_lb_listener resource
resource "aws_lb_listener" "http" {
    load_balancer_arn   = aws_lb.example.arn
    port                = local.http_port
    protocol            = "HTTP"

    # By default, return a simple 404 page
    default_action {
        type = "fixed-response"

        fixed_response {
            content_type    = "text/plain"
            message_body    = "404: page not found"
            status_code     = 404
        }
    }

}

# Create a security group for ALB
resource "aws_security_group" "alb" {
    name = "${var.cluster_name}-alb"
}
    
# Allow inbound HTTP requests
resource "aws_security_group_rule" "allow_http_inbound" {
    type                = "ingress"
    security_group_id   = aws_security_group.alb.id

    from_port       = local.http_port
    to_port         = local.http_port
    protocol        = local.tcp_protocol
    cidr_blocks     = local.all_ips
}

# Allow all outbound requests
resource "aws_security_group_rule" "allow_all_outbound" {
    type                = "egress"
    security_group_id   = aws_security_group.alb.id

    from_port       = local.any_port
    to_port         = local.any_port
    protocol        = local.any_protocol
    cidr_blocks     = local.all_ips
}


# Create a target group for your ASG using the aws_lb_target_group resource
resource "aws_lb_target_group" "asg" {
    name        = var.cluster_name
    port        = var.server_port
    protocol    = "HTTP"
    vpc_id      = data.aws_vpc.default.id

    health_check {
        path                = "/"
        protocol            = "HTTP"
        matcher             = "200"
        interval            = 15
        timeout             = 3
        healthy_threshold   = 2
        unhealthy_threshold = 2
    }

}

# Tie all the pieces together by creating listener rules
resource "aws_lb_listener_rule" "asg" {
    listener_arn    = aws_lb_listener.http.arn
    priority        = 100

    condition {
        path_pattern {
            values = ["*"]
        }
    }

    action {
        type                = "forward"
        target_group_arn    = aws_lb_target_group.asg.arn
    }
}


#terraform {
#    backend "s3" {
#        # bucket details
#        bucket          = "terraform-studyiac-state"
#        key             = "stage/services/webserver-cluster/terraform.tfstate"
#        region          = "us-east-2"
#
#        # DynamoDB table to use for locking details
#        dynamodb_table  = "terraform-studyiac-locks"
#        encrypt         = true
#    }
#}

data "terraform_remote_state" "db" {
    backend = "s3"

    config = {
        bucket  = var.db_remote_state_bucket
        key     = var.db_remote_state_key
        region  = "us-east-2"
    }
}


locals {
  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = ["0.0.0.0/0"]
}


# Lookup Default VPC in your AWS account
data "aws_vpc" "default" {
    default = true
}

# Lookup the subnets within default VPC
data "aws_subnets" "default" {
    filter {
        name   = "vpc-id"
        values = [data.aws_vpc.default.id]
    }
}
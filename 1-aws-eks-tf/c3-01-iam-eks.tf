# Data Block
data "aws_availability_zones" "aws_region" {
  state = "available"
}

# Locals Block 
locals {
  azs = slice(data.aws_availability_zones.aws_region.names, 0, 3)

}
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Para trabajar en equipo, guarde el estado en S3 (ver README.md, "Estado
  # de Terraform"). Mientras tanto el estado queda local, en terraform.tfstate.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Proyecto      = var.proyecto
      Entorno       = var.entorno
      GestionadoPor = "terraform"
    }
  }
}

locals {
  nombre = "${var.proyecto}-${var.entorno}"
}

data "aws_caller_identity" "actual" {}
data "aws_availability_zones" "disponibles" {
  #checkov:skip=CKV_AWS_394:Se usan solo las dos primeras zonas; una zona nueva no cambia la red
  state = "available"
}

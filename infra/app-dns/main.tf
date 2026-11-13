# Alias record for the vaultly ALB. The ALB belongs to the load balancer controller
# (created from the Gateway), so it is looked up here and never managed.
# Apply after scripts/gateway-apply.sh; destroy before scripts/gateway-teardown.sh.
locals {
  app_fqdn = "${var.app_hostname_label}.${var.zone_name}"
}

data "aws_route53_zone" "ih" {
  name         = var.zone_name
  private_zone = false
}

data "aws_lb" "app" {
  name = var.alb_name

  lifecycle {
    postcondition {
      condition     = self.load_balancer_type == "application" && !self.internal
      error_message = "the load balancer must be an internet-facing application load balancer"
    }
  }
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.ih.zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = data.aws_lb.app.dns_name
    zone_id                = data.aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

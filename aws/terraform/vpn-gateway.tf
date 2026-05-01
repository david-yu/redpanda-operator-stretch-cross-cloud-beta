# AWS Site-to-Site VPN gateway. Attached to the VPC; the customer_gateways
# and vpn_connections that point this at the GCP / Azure peers live in
# vpn/terraform/ (top-level module that has access to all three clouds'
# outputs).
#
# Routes propagation back into the VPC's route tables also happens in
# vpn/terraform/ — once we know which tables to add 10.20.0.0/16 (GCP)
# and 10.30.0.0/16 (Azure) routes to.

resource "aws_vpn_gateway" "this" {
  vpc_id          = module.vpc.vpc_id
  amazon_side_asn = var.vpn_aws_asn
  tags = {
    Name = "${var.cluster_name}-vgw"
  }
}

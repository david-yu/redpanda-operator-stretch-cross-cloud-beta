output "aws_to_gcp_tunnel" {
  value = {
    aws_outside_ip   = aws_vpn_connection.to_gcp.tunnel1_address
    aws_bgp_ip       = local.aws_to_gcp_aws_bgp_ip
    customer_bgp_ip  = local.aws_to_gcp_customer_bgp_ip
    gcp_tunnel_name  = google_compute_vpn_tunnel.to_aws.name
  }
}

output "aws_to_azure_tunnel" {
  value = {
    aws_outside_ip  = aws_vpn_connection.to_azure.tunnel1_address
    aws_bgp_ip      = local.aws_to_azure_aws_bgp_ip
    azure_lng_name  = azurerm_local_network_gateway.aws.name
  }
}

output "gcp_to_azure_tunnel" {
  value = {
    gcp_tunnel_name = google_compute_vpn_tunnel.to_azure_a.name
    gcp_bgp_ip      = local.gcp_to_azure_a_gcp_bgp_ip
    azure_lng_name  = azurerm_local_network_gateway.gcp.name
  }
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.region
  tags = {
    Project = var.project_name
  }
}

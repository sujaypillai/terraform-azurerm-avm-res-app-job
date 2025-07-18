terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}


## Section to provide a random Azure region for the resource group
# This allows us to randomize the region for the resource group.
module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "~> 0.1"
}

# This allows us to randomize the region for the resource group.
resource "random_integer" "region_index" {
  max = length(module.regions.regions) - 1
  min = 0
}
## End of section to provide a random Azure region for the resource group

# This ensures we have unique CAF compliant names for our resources.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~> 0.3"
}

# This is required for resource modules
resource "azurerm_resource_group" "this" {
  location = module.regions.regions[random_integer.region_index.result].name
  name     = module.naming.resource_group.name_unique
}

resource "azurerm_container_app_environment" "this" {
  location            = azurerm_resource_group.this.location
  name                = "my-environment"
  resource_group_name = azurerm_resource_group.this.name
}

# Service Bus namespace for event trigger example
resource "azurerm_servicebus_namespace" "this" {
  location            = azurerm_resource_group.this.location
  name                = "${module.naming.servicebus_namespace.name_unique}-event-trigger"
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
}

# Service Bus queue for event trigger example
resource "azurerm_servicebus_queue" "this" {
  name         = "my-queue"
  namespace_id = azurerm_servicebus_namespace.this.id
}

# Service Bus authorization rule for connection string
resource "azurerm_servicebus_namespace_authorization_rule" "this" {
  name         = "RootManageSharedAccessKey"
  namespace_id = azurerm_servicebus_namespace.this.id
  listen       = true
}

# Container App Environment secret for Service Bus connection
resource "azurerm_container_app_environment_certificate" "servicebus_connection" {
  certificate_blob_base64      = base64encode(azurerm_servicebus_namespace_authorization_rule.this.primary_connection_string)
  certificate_password         = ""
  container_app_environment_id = azurerm_container_app_environment.this.id
  name                         = "servicebus-connection"
}

# This is the module call
# Do not specify location here due to the randomization above.
# Leaving location as `null` will cause the module to use the resource group location
# with a data source.

# This module creates a container app with a manual trigger.
module "manual_trigger" {
  source = "../../"

  container_app_environment_resource_id = azurerm_container_app_environment.this.id
  location                              = azurerm_resource_group.this.location
  name                                  = "${module.naming.container_app.name_unique}-job-mt"
  resource_group_name                   = azurerm_resource_group.this.name
  template = {
    container = {
      name    = "my-container"
      image   = "docker.io/ubuntu"
      command = ["echo"]
      args    = ["Hello, World!"]
      cpu     = 0.5
      memory  = "1Gi"
    }
  }
  enable_telemetry = var.enable_telemetry
  trigger_config = {
    manual_trigger_config = {
      parallelism              = 1
      replica_completion_count = 1
    }
  }
}

# This module creates a container app with a schedule_trigger.
module "schedule_trigger" {
  source = "../../"

  container_app_environment_resource_id = azurerm_container_app_environment.this.id
  location                              = azurerm_resource_group.this.location
  name                                  = "${module.naming.container_app.name_unique}-job-st"
  resource_group_name                   = azurerm_resource_group.this.name
  template = {
    container = {
      name    = "my-container"
      image   = "docker.io/ubuntu"
      command = ["echo"]
      args    = ["Hello, World!"]
      cpu     = 0.5
      memory  = "1Gi"
    }
  }
  managed_identities = {
    system_assigned = true
  }
  trigger_config = {
    schedule_trigger_config = {
      cron_expression          = "0 * * * *"
      parallelism              = 1
      replica_completion_count = 1
    }
  }
}

# This module creates a container app with an event_trigger.
module "event_trigger" {
  source = "../../"

  container_app_environment_resource_id = azurerm_container_app_environment.this.id
  location                              = azurerm_resource_group.this.location
  name                                  = "${module.naming.container_app.name_unique}-job-et"
  resource_group_name                   = azurerm_resource_group.this.name
  template = {
    container = {
      name    = "my-container"
      image   = "docker.io/ubuntu"
      command = ["echo"]
      args    = ["Hello, World!"]
      cpu     = 0.5
      memory  = "1Gi"
    }
  }
  managed_identities = {
    system_assigned = true
  }
  trigger_config = {
    event_trigger_config = {
      parallelism              = 1
      replica_completion_count = 1
      scale = {
        max_executions              = 10
        min_executions              = 1
        polling_interval_in_seconds = 30
        rules = {
          name             = "my-custom-rule"
          custom_rule_type = "azure-servicebus"
          metadata = {
            "queueName" = "my-queue"
          }
          authentication = {
            secret_name       = "servicebus-connection"
            trigger_parameter = "connection"
          }
        }
      }
    }
  }
}

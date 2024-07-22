targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name which is used to generate a short unique hash for each resource')
param name string

@minLength(1)
@description('Primary location for all resources')
param location string

var dbserverPassword = '' // Only used by the linter

@secure()
@description('Secret Key')
param secretKey string

@description('Id of the user or app to assign application roles')
param principalId string = ''

var resourceToken = toLower(uniqueString(subscription().id, name, location))
var prefix = '${name}-${resourceToken}'
var tags = { 'azd-env-name': name }

var DATABASE_RESOURCE = 'cosmos-mongodb'
var PROJECT_HOST = 'appservice'

var secrets = [
  {
    name: 'SECRETKEY'
    value: secretKey
  }
]

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${name}-rg'
  location: location
  tags: tags
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.1.8' = {
  name: 'virtualNetworkDeployment'
  scope: resourceGroup
  params: {
    // Required parameters
    addressPrefixes: [
      '10.0.0.0/16'
    ]
    name: '${name}-vnet'
    location: location
    tags: tags
    subnets: [
      {
        addressPrefix: '10.0.0.0/24'
        name: 'keyvault'
        tags: tags
      }
      {
        addressPrefix: '10.0.2.0/23'
        name: 'web'
        tags: tags
        delegations: [
          {
            name: 'msft-web-serverfarm-delegation'
            properties: {
              serviceName: 'Microsoft.Web/serverFarms'
            }
          }
        ]
        serviceEndpoints: [
          {
            service: 'Microsoft.KeyVault'
          }
          {
            service: 'Microsoft.AzureCosmosDB'
          }
        ]
      }
      {
        addressPrefix: '10.0.4.0/23'
        name: 'db'
        tags: tags
        serviceEndpoints: []
      }
    ]
  }
}

module cosmosMongoPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.3.1' = {
  name: 'cosmosMongoPrivateDnsZone'
  scope: resourceGroup
  params: {
    name: 'privatelink.mongo.cosmos.azure.com'
    tags: tags
  }
}

module keyvaultPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.3.1' = {
  name: 'keyvaultPrivateDnsZone'
  scope: resourceGroup
  params: {
    name: 'privatelink.vaultcore.azure.net'
    tags: tags
  }
}

// Store secrets in a keyvault
module keyVault 'br/public:avm/res/key-vault/vault:0.6.2' = {
  name: 'keyvault'
  scope: resourceGroup
  params: {
    name: '${take(replace(prefix, '-', ''), 17)}-vault'
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    accessPolicies: [
      {
        objectId: principalId
        permissions: { secrets: ['get', 'list'] }
        tenantId: subscription().tenantId
      }
    ]
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      // ipRules: [
      //   { value: '<your IP>' }
      // ]
      virtualNetworkRules: [
        {
          id: virtualNetwork.outputs.subnetResourceIds[1]
        }
      ]
    }
    privateEndpoints: [
      {
        name: '${name}-keyvault-pe'
        subnetResourceId: virtualNetwork.outputs.subnetResourceIds[0]
        privateDnsZoneResourceIds: [keyvaultPrivateDnsZone.outputs.resourceId]
      }
    ]
    diagnosticSettings: [
      {
        logCategoriesAndGroups: [
          {
            category: 'AuditEvent'
          }
        ]
        name: 'auditEventLogging'
        workspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceId
      }
    ]
    secrets: [
      for secret in secrets: {
        name: secret.name
        value: secret.value
        tags: tags
        attributes: {
          exp: 0
          nbf: 0
        }
      }
    ]
  }
}

module roleAssignment 'core/security/role.bicep' = {
  name: 'webRoleAssignment'
  scope: resourceGroup
  params: {
    principalId: web.outputs.SERVICE_WEB_IDENTITY_PRINCIPAL_ID
    roleDefinitionId: '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
  }
}

module cosmosMongoDb 'db/cosmos-mongodb.bicep' = if (DATABASE_RESOURCE == 'cosmos-mongodb') {
  name: 'cosmosMongoDb'
  scope: resourceGroup
  params: {
    name: 'dbserver'
    location: location
    tags: tags
    prefix: prefix
    dbserverDatabaseName: 'relecloud'
    sqlRoleAssignmentPrincipalId: web.outputs.SERVICE_WEB_IDENTITY_PRINCIPAL_ID
    keyvaultName: keyVault.outputs.name
    privateDNSZoneResourceId: cosmosMongoPrivateDnsZone.outputs.resourceId
    subnetResourceId: virtualNetwork.outputs.subnetResourceIds[2]
    applicationSubnetResourceId: virtualNetwork.outputs.subnetResourceIds[1]
  }
}

module cosmosPostgres 'db/cosmos-postgres.bicep' = if (DATABASE_RESOURCE == 'cosmos-postgres') {
  name: 'cosmosPostgres'
  scope: resourceGroup
  params: {
    name: 'dbserver'
    location: location
    tags: tags
    prefix: prefix
    dbserverDatabaseName: 'relecloud'
    dbserverPassword: dbserverPassword
  }
}

module postgresFlexible 'db/postgres-flexible.bicep' = if (DATABASE_RESOURCE == 'postgres-flexible') {
  name: 'postgresFlexible'
  scope: resourceGroup
  params: {
    name: 'dbserver'
    location: location
    tags: tags
    prefix: prefix
    dbserverDatabaseName: 'relecloud'
    dbserverPassword: dbserverPassword
  }
}

// Monitor application with Azure Monitor
module monitoring 'core/monitor/monitoring.bicep' = {
  name: 'monitoring'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    applicationInsightsDashboardName: '${prefix}-appinsights-dashboard'
    applicationInsightsName: '${prefix}-appinsights'
    logAnalyticsName: '${take(prefix, 50)}-loganalytics' // Max 63 chars
  }
}

// Web frontend
module web 'web.bicep' = {
  name: 'web'
  scope: resourceGroup
  params: {
    name: replace('${take(prefix,19)}-appsvc', '--', '-')
    location: location
    tags: tags
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    keyVaultName: keyVault.outputs.name

    appCommandLine: 'entrypoint.sh'
    pythonVersion: '3.12'
    virtualNetworkSubnetId: virtualNetwork.outputs.subnetResourceIds[1]
  }
}

output AZURE_LOCATION string = location
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output APPLICATIONINSIGHTS_NAME string = monitoring.outputs.applicationInsightsName

output BACKEND_URI string = web.outputs.uri

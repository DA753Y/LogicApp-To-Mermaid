const myWorkflow = {
  "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
  "contentVersion": "1.0.0.0",
  "triggers": {
    "HTTP_Trigger": {
      "type": "Request",
      "kind": "Http"
    }
  },
  "actions": {
    "Compose_Greeting": {
      "type": "Compose",
      "inputs": "Hello World",
      "runAfter": {}
    }
  }
};

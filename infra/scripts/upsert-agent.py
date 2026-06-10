# upsert-agent.py — ensure a persistent Foundry agent NAMED $AGENT_NAME exists in the project with
# the given persona ($AGENT_INSTRUCTIONS) and model ($MODEL_DEPLOYMENT_NAME). Idempotent
# upsert-by-NAME: create if absent, else update the existing same-named agent in place. The agent
# is retrieved at runtime by NAME (AgentReference), so this emits only the agent name (no asst_ id).
#
# Auth: the deploymentScript runs as a user-assigned managed identity (UAMI) granted Azure AI
# Developer on the Foundry account; we authenticate with ManagedIdentityCredential(client_id=...).
#
# [DEPLOY-VERIFY] The exact azure-ai-agents / azure-ai-projects Python SDK surface (client class,
# list/create/update method names and their kwargs) is a DEPLOY-TIME unknown — this is the most
# plausible shape against the current preview SDKs. If a name/signature is wrong, the fix is local:
# the create-vs-update branch below is intentionally obvious. Verified at deploy against the SDK
# version pinned by agent.bicep's `pip install`.

import json
import os
import sys
import time

from azure.identity import ManagedIdentityCredential

# [DEPLOY-VERIFY] Client surface. Two plausible import paths depending on the installed SDK:
#   (a) azure-ai-agents:   from azure.ai.agents import AgentsClient; AgentsClient(endpoint, credential)
#   (b) azure-ai-projects: from azure.ai.projects import AIProjectClient; project.agents.<...>
# We use (a) here; if only (b) is installed, swap to project.agents and the same method names.
from azure.ai.agents import AgentsClient  # [DEPLOY-VERIFY] import path / client class name

ENDPOINT = os.environ["PROJECT_ENDPOINT"]
MODEL = os.environ["MODEL_DEPLOYMENT_NAME"]
NAME = os.environ["AGENT_NAME"]
INSTRUCTIONS = os.environ["AGENT_INSTRUCTIONS"]
CLIENT_ID = os.environ["UAMI_CLIENT_ID"]

credential = ManagedIdentityCredential(client_id=CLIENT_ID)
client = AgentsClient(endpoint=ENDPOINT, credential=credential)

agent = None
last_error = None
# Retry ~6 minutes (12 x 30s) to tolerate role-assignment propagation 403s after deploy.
for attempt in range(12):
    try:
        # [DEPLOY-VERIFY] list/create/update method names + kwargs.
        existing = next((a for a in client.list_agents() if a.name == NAME), None)
        if existing is not None:
            # Update the existing same-named agent in place (keeps the name stable across deploys).
            agent = client.update_agent(
                existing.id,
                model=MODEL,
                name=NAME,
                instructions=INSTRUCTIONS,
            )
        else:
            # Create a new agent with the desired name.
            agent = client.create_agent(
                model=MODEL,
                name=NAME,
                instructions=INSTRUCTIONS,
            )
        break
    except Exception as e:  # noqa: BLE001 — retry any transient/auth-propagation error
        last_error = e
        sys.stderr.write(f"attempt {attempt}: {e}\n")
        time.sleep(30)
else:
    raise SystemExit(f"agent upsert failed after retries: {last_error}")

# Emit ONLY the agent name (+ version if the SDK exposes one) — retrieval is name-keyed; no asst_ id.
output = {"agentName": NAME}
version = getattr(agent, "version", None)  # [DEPLOY-VERIFY] attribute name if a version is exposed
if version is not None:
    output["agentVersion"] = str(version)

with open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w") as f:
    json.dump(output, f)

print(f"agent upserted by name: {NAME}")

# upsert-agent.py — ensure a persistent Foundry agent NAMED $AGENT_NAME exists in the project with
# the given persona ($AGENT_INSTRUCTIONS) and model ($MODEL_DEPLOYMENT_NAME). The agent is retrieved
# at runtime BY NAME (.NET AgentReference -> Responses `agent_reference`), so this emits only the
# agent name (no asst_ id).
#
# SDK surface (verified against azure-ai-projects 2.0.0b2, api 2025-11-15-preview):
#   AIProjectClient(endpoint, credential).agents
#     .create_version(agent_name, *, definition=AgentDefinition) -> AgentVersionObject  # add a version
#     .create(*, name, definition=AgentDefinition)              -> AgentObject          # create + v1
#     .get(agent_name)                                          -> AgentObject
#   PromptAgentDefinition(*, model, instructions)  # the "simple agent" definition (kind='prompt')
# This matches the .NET runtime, which resolves the agent by name and calls it as an agent_reference.
# Each deploy publishes a NEW version with the current persona; name-keyed retrieval gets the latest.
#
# Auth: the deploymentScript runs as a user-assigned managed identity (UAMI) granted Azure AI
# Developer on the Foundry account; we authenticate with ManagedIdentityCredential(client_id=...).

import json
import os
import sys
import time

from azure.identity import ManagedIdentityCredential
from azure.core.exceptions import ResourceNotFoundError
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition

ENDPOINT = os.environ["PROJECT_ENDPOINT"]
MODEL = os.environ["MODEL_DEPLOYMENT_NAME"]
NAME = os.environ["AGENT_NAME"]
INSTRUCTIONS = os.environ["AGENT_INSTRUCTIONS"]
CLIENT_ID = os.environ["UAMI_CLIENT_ID"]

credential = ManagedIdentityCredential(client_id=CLIENT_ID)
project = AIProjectClient(endpoint=ENDPOINT, credential=credential)


def upsert():
    """Upsert the agent by NAME. create_version adds a version to the named agent; if the agent does
    not exist yet (first deploy), create it (which also publishes its first version)."""
    definition = PromptAgentDefinition(model=MODEL, instructions=INSTRUCTIONS)
    try:
        return project.agents.create_version(agent_name=NAME, definition=definition)
    except ResourceNotFoundError:
        # First deploy: the named agent doesn't exist yet -> create it (+ v1).
        return project.agents.create(name=NAME, definition=definition)


result = None
last_error = None
# Retry ~6 minutes (12 x 30s) to tolerate role-assignment propagation 403s right after deploy.
# ResourceNotFoundError is handled INSIDE upsert() (create-if-absent), so it never lands here.
for attempt in range(12):
    try:
        result = upsert()
        break
    except Exception as e:  # noqa: BLE001 — retry any transient/auth-propagation error
        last_error = e
        sys.stderr.write(f"attempt {attempt}: {type(e).__name__}: {e}\n")
        time.sleep(30)
else:
    raise SystemExit(f"agent upsert failed after retries: {last_error}")

# Emit ONLY the agent name (+ version if exposed) — retrieval is name-keyed; no asst_ id.
output = {"agentName": NAME}
version = getattr(result, "agentVersion", None) or getattr(result, "version", None)
if version is not None:
    output["agentVersion"] = str(version)

with open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w") as f:
    json.dump(output, f)

print(f"agent upserted by name: {NAME} (version: {output.get('agentVersion', 'n/a')})")

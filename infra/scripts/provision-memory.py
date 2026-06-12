# provision-memory.py — ensure a Foundry memory store NAMED $MEMORY_STORE_NAME exists with the given
# TTL + models, and bind it to the agent NAMED $AGENT_NAME. Runs as the provisioning UAMI (the same
# identity that authors the agent in upsert-agent.py, granted Azure AI Developer on the account).
#
# Memory is a DATA-PLANE object with no ARM resource type, so — exactly like the agent — it is created
# via a deploymentScript running this file against the project endpoint.
#
# [DEPLOY-VERIFY] Memory is PREVIEW. The names below reflect the DOCUMENTED shape
# (MemoryStoreDefaultOptions.default_ttl_seconds, api 2025-11-15-preview); confirm the exact
# module/method/param names against the installed azure-ai-projects 2.0.0b2 build before relying on
# this. TTL is set at CREATE time; default_ttl_seconds == 0 means NO expiry.
#
# [DEPLOY-VERIFY] BINDING: memory may attach to the agent DEFINITION (a memory tool) rather than via a
# standalone call. If so, the attach belongs in upsert-agent.py, and per-user/thread memory scoping
# may require an app-side run parameter (which WOULD be an application change). See memory.bicep header.

import os
import sys
import time

from azure.identity import ManagedIdentityCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MemoryStoreDefaultOptions  # [verify class path]

ENDPOINT = os.environ["PROJECT_ENDPOINT"]
CHAT = os.environ["CHAT_DEPLOYMENT_NAME"]          # extraction / consolidation model
EMBED = os.environ["EMBEDDING_DEPLOYMENT_NAME"]    # retrieval model
AGENT = os.environ["AGENT_NAME"]                   # bind the store to this agent
STORE = os.environ["MEMORY_STORE_NAME"]
TTL = int(os.environ["MEMORY_TTL_SECONDS"])        # 0 = no expiry
CLIENT_ID = os.environ["UAMI_CLIENT_ID"]

credential = ManagedIdentityCredential(client_id=CLIENT_ID)
project = AIProjectClient(endpoint=ENDPOINT, credential=credential)


def upsert():
    """Idempotent: create the memory store if absent, else update its default options (TTL + models).
    Then bind it to the named agent so the agent's runs read/write this memory."""
    options = MemoryStoreDefaultOptions(default_ttl_seconds=TTL)  # + procedural-memory toggle, etc.
    store = project.memory_stores.create_or_update(  # [verify method]
        name=STORE,
        default_options=options,
        chat_model=CHAT,
        embedding_model=EMBED,
    )
    # [verify] standalone bind vs. memory-tool-on-agent-definition (see header).
    project.agents.attach_memory(agent_name=AGENT, memory_store=store.name)  # [verify]
    return store


result = None
last_error = None
# Same role-propagation retry envelope as upsert-agent.py (~6 min: 12 x 30s) to tolerate 403s right
# after the role assignment is created.
for attempt in range(12):
    try:
        result = upsert()
        break
    except Exception as e:  # noqa: BLE001 — retry any transient/auth-propagation error
        last_error = e
        sys.stderr.write(f"attempt {attempt}: {type(e).__name__}: {e}\n")
        time.sleep(30)
else:
    raise SystemExit(f"memory provision failed after retries: {last_error}")

with open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w") as f:
    import json
    json.dump({"memoryStoreName": STORE, "ttlSeconds": TTL}, f)

print(f"memory store provisioned: {STORE} (ttl={TTL}s) bound to agent {AGENT}")

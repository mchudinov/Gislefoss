# provision-memory.py — ensure a Foundry memory store NAMED $MEMORY_STORE_NAME exists with the given
# chat + embedding models. Runs as the provisioning UAMI (the same identity that authors the agent in
# upsert-agent.py, granted Azure AI Developer on the account).
#
# A memory store is a DATA-PLANE object with no ARM resource type, so — exactly like the agent — it is
# created via a deploymentScript running this file against the project endpoint.
#
# SDK surface (verified against the INSTALLED azure-ai-projects 2.0.0b2 build, not the public >=2.0.0
# docs which differ):
#   AIProjectClient(endpoint, credential).memory_stores      # NOT `.beta.memory_stores`
#     .get(name)                                              -> MemoryStoreObject (404 -> ResourceNotFound)
#     .create(*, name, definition=MemoryStoreDefinition, description=) -> MemoryStoreObject
#     .update(name, *, description=, metadata=)               # canNOT change models/options post-create
#   MemoryStoreDefaultDefinition(*, chat_model, embedding_model, options)
#   MemoryStoreDefaultOptions(*, user_profile_enabled, user_profile_details, chat_summary_enabled)
#
# BINDING: there is NO `attach_memory` on this SDK. The store is bound to the agent by adding a
# MemorySearchTool to the agent's own PromptAgentDefinition — that lives in upsert-agent.py (gated on
# MEMORY_STORE_NAME), NOT here. This module's single job is to make the store exist first.
#
# TTL: MemoryStoreDefaultOptions in 2.0.0b2 has NO `default_ttl_seconds` (that field is stable-2.0.0+
# only), so retention cannot be set on this pin. MEMORY_TTL_SECONDS is read only to warn when a
# non-default value is requested but cannot be honored — bump the SDK pin to apply TTL.
#
# Models/options are fixed at CREATE time (update() only takes description/metadata). To change the
# chat/embedding model or the option toggles, delete and recreate the store.

import os
import sys
import time

from azure.identity import ManagedIdentityCredential
from azure.core.exceptions import ResourceNotFoundError
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MemoryStoreDefaultDefinition, MemoryStoreDefaultOptions

ENDPOINT = os.environ["PROJECT_ENDPOINT"]
CHAT = os.environ["CHAT_DEPLOYMENT_NAME"]          # extraction / consolidation model
EMBED = os.environ["EMBEDDING_DEPLOYMENT_NAME"]    # retrieval model
STORE = os.environ["MEMORY_STORE_NAME"]
TTL = int(os.environ.get("MEMORY_TTL_SECONDS", "0"))
CLIENT_ID = os.environ["UAMI_CLIENT_ID"]

if TTL:
    sys.stderr.write(
        f"NOTE: MEMORY_TTL_SECONDS={TTL} requested, but azure-ai-projects 2.0.0b2 has no "
        "default_ttl_seconds on MemoryStoreDefaultOptions; the store is created with NO expiry. "
        "Bump the SDK pin to honor TTL.\n"
    )

credential = ManagedIdentityCredential(client_id=CLIENT_ID)
project = AIProjectClient(endpoint=ENDPOINT, credential=credential)


def upsert():
    """Idempotent get-or-create. The store's models/options are immutable after creation, so an
    existing store is returned as-is (recreate to change them)."""
    try:
        store = project.memory_stores.get(STORE)
        print(f"memory store already exists: {STORE}")
        return store
    except ResourceNotFoundError:
        options = MemoryStoreDefaultOptions(
            user_profile_enabled=True,
            chat_summary_enabled=True,
        )
        definition = MemoryStoreDefaultDefinition(
            chat_model=CHAT,
            embedding_model=EMBED,
            options=options,
        )
        store = project.memory_stores.create(
            name=STORE,
            definition=definition,
            description="Gislefoss meteorologist agent long-term memory",
        )
        print(f"memory store created: {STORE}")
        return store


result = None
last_error = None
# Same role-propagation retry envelope as upsert-agent.py (~6 min: 12 x 30s) to tolerate 403s right
# after the role assignment is created. ResourceNotFoundError is handled INSIDE upsert(), not here.
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
    json.dump({"memoryStoreName": STORE}, f)

print(f"memory store provisioned: {STORE} (chat={CHAT}, embedding={EMBED})")

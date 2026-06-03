# Meteorologist AI agent

## Functional requirements

1. AI agent only answers weather related questions.

It will answer about the weather at the given place on Earth.

Agent may guess about the weather in the past or future.

If the question is unclear (like no place given) it will ask about.

Examples:

- What is the weather like today in Oslo?
- What was the weather like in Paris 100 years ago?
- What will be the weather at the South Pole in 100 years?

2. If the question is not weather related agent denys to answer.

## Non-functional requirements

1. Agent is programmed using Micorosft Agent Framework
2. Agent is running in Azure AI Foundry
3. Agent uses OpenAI model
4. Agent must be protected against prompt injections
5. Agent must have prompt shields
6. Agent must have content filter metadata - inspect provider response
7. Agent infrastructure is deployed using Bicep code

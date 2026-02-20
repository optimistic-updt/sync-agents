# Sync Agents

Everyone in a company likely uses different AI agents. Even if everyone is using the same one, it's beneficial to experiment with others.

To improve agent quality and standardize the workflow, I've created this little bash script to centralize agent knowledge and propagate it to the various providers.

## How to Use

The `./.agents/` directory serves as the centralized location for all skills, agents, `AGENTS.md`, etc. Whenever you modify that folder, run `make sync-agents` to sync it with the various providers' directories.

## Extend

To add more providers, simply include the configuration in the [provider list at the top of the script](./scripts/sync-agents.sh:6).

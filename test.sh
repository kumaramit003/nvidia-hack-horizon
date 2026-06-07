nemoclaw "$SANDBOX" exec -- bash -lc 'chmod -R a+rwX /sandbox/.openclaw'


nemoclaw my-assistant exec -- bash -lc 'mkdir -p /sandbox/.local/bin'
nemoclaw my-assistant exec -- bash -lc 'npm install -g mcporter --prefix /sandbox/.local || npm install -g mcporter --prefix /tmp/npm-global'
nemoclaw my-assistant exec -- bash -lc 'export PATH="/sandbox/.local/bin:/tmp/npm-global/bin:$PATH"; mcporter --version'


nemoclaw my-assistant exec -- bash -lc 'export PATH="/sandbox/.local/bin:/tmp/npm-global/bin:$PATH"; mcporter config remove govuk 2>/dev/null || true; mcporter config add govuk https://govuk-mcp.fly.dev/mcp --transport http --scope home'
nemoclaw my-assistant exec -- bash -lc 'export PATH="/sandbox/.local/bin:/tmp/npm-global/bin:$PATH"; mcporter config add uk-property https://uk-property-mcp.fly.dev/mcp --transport http --scope home'
nemoclaw my-assistant exec -- bash -lc 'export PATH="/sandbox/.local/bin:/tmp/npm-global/bin:$PATH"; mcporter config add playwright --command "npx -y @playwright/mcp@latest" --transport stdio --scope home'

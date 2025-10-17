---
name: security
description: Run policy checks (optional) and summarize results.
inputs: repo, policies/quality-gates.json, policies/security-policy.json
outputs: artifacts/security_summary.json
tools: ['Read', 'Write']
verbosity: low
---
If disabled via config, output a skipped summary; else summarize issues based on policies.

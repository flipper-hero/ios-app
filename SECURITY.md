# Security

FlipperHero lets a language model operate real hardware, so we take reports seriously.

## Reporting

Please use GitHub's private vulnerability reporting ("Report a vulnerability" on the Security tab of
this repository). Do not open a public issue for security problems.

## What we especially want to hear about

- Ways to make the agent run an action without the approval the risk model requires.
- Prompt injection through content on the Flipper, downloaded files, search results or images that
  gets past the untrusted-content fencing or the taint rule.
- Ways for the agent to change its own permissions without the consent dialog, including arming
  engagement mode or its capabilities on its own, or reaching a capability-gated tool
  (`rpc_raw`, `badusb_execute`) while it is not armed.
- Anything that exposes the API key.

## Out of scope

What the Flipper Zero itself can do is governed by its firmware, including regional transmit
restrictions. FlipperHero does not bypass firmware limits.

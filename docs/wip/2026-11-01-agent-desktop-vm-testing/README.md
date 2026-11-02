# Agent Desktop VM testing

Open [the HTML research report](index.html) or [research and run instructions](research.md).

Prepared: one macOS golden image and two disposable workers. Both parallel guest AX calculator smokes passed; all VMs are stopped. [lab.sh](lab.sh) targets worker 1 by default and keeps the golden image unchanged. Runtime tools, VM disks and private connection logs are in ignored tmp/test-labs/2026-11-01-agent-desktop-vm.

The HTML uses the shared online Demistify theme/runtime. This is saved local research and a working external-tool pilot, not a product test-runner change or AgentStudio UI acceptance.

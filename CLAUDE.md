
# macSandbox Development Rules & Guidelines

## Guidelines

- Configuration and code should make the tool portable so others running macOS 26+ can use the tool
- Always ensure the containerfile follows Containerfile / Dockerfile best practices for security, caching and performance
- Be careful not to break the persisted login state of Claude within the container, the user should not have to log in after the container is restarted or recreated

## Reference Links

- Apple Containers - Commands docs: https://raw.githubusercontent.com/apple/container/refs/heads/main/docs/command-reference.md
- Apple Containers - Tutorial docs: https://raw.githubusercontent.com/apple/container/refs/heads/main/docs/tutorial.md

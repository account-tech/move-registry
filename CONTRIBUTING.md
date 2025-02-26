# Contributing to Move Registry

Thank you for your interest in contributing to Move Registry! This repository contains a collection of smart account implementations for the Sui blockchain, built on our move-framework.

## Repository Structure

```
move-registry/
├── packages/                # Smart account implementations
│   ├── core/                # Core team maintained implementations
│   └── community/           # Community contributed implementations
├── templates/               # Templates for new implementations
└── docs/                    # Documentation
```

## Development Workflow

We follow a fork and pull request workflow:

1. **Fork the Repository**: Create your own fork from the main branch
2. **Create a new branch**: Use the prefix `config/` for new account configs, `feature/` for new features, `fix/` for bug fixes, `chore/` for other changes
3. **Make Changes**: Implement your smart account in the `packages/community/` directory
4. **Test**: Ensure proper test coverage and that all tests pass
5. **Commit Changes**: Use clear, descriptive commit messages
6. **Submit a Pull Request**: Create a PR from your fork to the main repository

## Implementation Guidelines

- Each smart account implementation should be in its own package
- Follow the template in [templates/account_config_template.move](templates/account_config_template.move)
- Use the same name for your smart account config everywhere
- Follow [Move Conventions](https://docs.sui.io/concepts/sui-move-concepts/conventions)
- Include clear comments explaining the purpose and functionality

---

Thank you for contributing to Move Registry and helping build the future of next-gen dapps on Sui!
# account.tech - Move Registry

This repository contains the Move source code for different Account implementations.

## Account Types Overview

| Type                                | Description                                                                                | Use Cases                        | Status                      | Contributors                           |
|-------------------------------------|--------------------------------------------------------------------------------------------|----------------------------------|-----------------------------|----------------------------------------|
| [Multisig](./multisig/)             | Account requiring M-of-N signatures                                                        | Treasuries, Developers, Creators | Fully tested, pending audit | [@thounyy](https://github.com/thounyy) |
| [P2P Ramp](../../packages/community/p2p) | Account for exchanging crypto and fiat with escrow protection | Merchants, KYC-free | Not tested, not audited     | [@thounyy](https://github.com/thounyy) [@astinz](https://github.com/astinz)  |

## Contributing a New Account Type

To contribute a new account type to the registry, please follow the guidelines below and feel free to message us on [Telegram](https://t.me/Thouny) or [Twitter](https://x.com/BL0CKRUNNER) if you have any questions.

### Development Workflow

We follow a fork and pull request workflow:

1. **Fork the Repository**: Create your own fork from the main branch
2. **Create a new branch**: Use the prefix `config/` for new account configs, `feature/` for new features, `fix/` for bug fixes, `chore/` for other changes
3. **Make Changes**: Implement your smart account in the `packages/community/` directory
4. **Test**: Ensure proper test coverage and that all tests pass
5. **Commit Changes**: Use clear, descriptive commit messages
6. **Submit a Pull Request**: Create a PR from your fork to the main repository

### Implementation Guidelines

- Each smart account implementation should be in its own package
- Follow the implementation guide in [our docs](https://docs.account.tech).
- Use the same name for your smart account config everywhere
- Follow [Move Conventions](https://docs.sui.io/concepts/sui-move-concepts/conventions)
- Include clear comments explaining the purpose and functionality
- Write a short README in your config directory by duplicating the [Template](./TEMPLATE.md)
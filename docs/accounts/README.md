# Account Types

This directory contains documentation for all smart account implementations in the registry.

## Account Types Overview

| Type                                | Description                                                                                | Use Cases                        | Status                      | Contributors                           |
|-------------------------------------|--------------------------------------------------------------------------------------------|----------------------------------|-----------------------------|----------------------------------------|
| [Multisig](./multisig/)             | Account requiring M-of-N signatures                                                        | Treasuries, Developers, Creators | Fully tested, pending audit | [@thounyy](https://github.com/thounyy) |
| [P2P](../../packages/community/p2p) | An account that enables buyers and sellers to trade crypto and fiat directly with escrow protection | Merchants, Creators, Ambassadors | Not tested, not audited     | [@astinz](https://github.com/astinz)   |

## Contributing a New Account Type

To contribute a new account type to the registry, please follow our [Contribution Guide](../../CONTRIBUTING.md) and start by duplicating the [Account Documentation Template](./_template.md).
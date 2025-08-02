# Grant

This project is a major refactor and improvement over the original project Granite.

Renaming to Grant is to create a personification of the framework. This is part of the overall larger brand shift happening with the Amber framework.

When creating a work plan, never estimate the time required.

## Tests

The test suite needs to cover every feature. We are currently working toward building feature parity with Active Record from Ruby. To do this, we need to track the library features that we want to create parity with.

Local testing is done using sqlite.

CI/CD testing uses sqlite, postgres and mysql. Our CI/CD pipeline is on Github Actions.

## Current Project Conventions

All branches follow: `feature/phase-{number}-{feature-group-name}` naming convention.


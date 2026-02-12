  docker/
  ├── docker-compose.yml    # All 5 services with dependency chain
  └── .env                  # Provisioning URL placeholders

  Startup order is enforced via depends_on with condition: service_healthy:
  ┌───────┬──────────┬───────────────────────────────┐
  │ Phase │ Service  │         Starts after          │
  ├───────┼──────────┼───────────────────────────────┤
  │ 1     │ AHA      │ Nothing                       │
  ├───────┼──────────┼───────────────────────────────┤
  │ 2     │ Axon     │ AHA healthy                   │
  ├───────┼──────────┼───────────────────────────────┤
  │ 2     │ JSONStor │ AHA healthy                   │
  ├───────┼──────────┼───────────────────────────────┤
  │ 3     │ Cortex   │ AHA + Axon + JSONStor healthy │
  ├───────┼──────────┼───────────────────────────────┤
  │ 4     │ Optic    │ AHA + Cortex + Axon healthy   │
  └───────┴──────────┴───────────────────────────────┘
  Provisioning workflow:

  # 1. Start AHA
  docker compose up -d aha

  # 2. Generate provisioning URLs
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.axon
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.jsonstor
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.cortex
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.optic

  # 3. Paste URLs into .env file

  # 4. Start everything
  docker compose up -d

  Optic UI will be available at https://localhost:4443.

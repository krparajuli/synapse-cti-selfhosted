  docker/
  ├── docker-compose.yml    # All 5 services with dependency chain
  └── .env                  # Provisioning URL placeholders

Steps:

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

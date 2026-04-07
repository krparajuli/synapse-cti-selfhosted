  docker/
  ├── docker-compose.yml    # All 5 services with dependency chain
  ├── .env                  # Provisioning URL placeholders
  ├── env-getter.sh         # Generates provisioning URLs from a running AHA
  └── Makefile              # Deployment targets

Using Make (recommended):

  # 1. Start AHA and generate provisioning URLs in one step
  make init

  # 2. Copy the printed URLs into .env
  #    (they are also saved in gen-env.txt for reference)

  # 3. Start all services
  make up

  Optic UI will be available at https://localhost:4443.

Other useful targets:

  make down      # Stop all services (data volumes preserved)
  make restart   # Restart running services
  make logs      # Tail logs for all services
  make clean     # Stop services and DELETE all volume data (destructive)
  make help      # Show all targets

Manual steps (without Make):

  # 1. Start AHA
  docker compose up -d aha

  # 2. Generate provisioning URLs
  sh env-getter.sh          # writes URLs to gen-env.txt
  # or run each command individually:
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.axon
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.jsonstor
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.cortex
  docker compose exec aha python -m synapse.tools.aha.provision.service 00.optic

  # 3. Paste URLs into .env file

  # 4. Start everything
  docker compose --env-file .env up -d

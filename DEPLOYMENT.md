# Deployment Guide

This guide covers deploying NervousSystem to production environments.

## Prerequisites

- Elixir 1.15+ and Erlang/OTP 26+
- Docker (optional, for containerized deployment)
- API keys for LLM providers:
  - Anthropic (required for Analyst, Historian, Ethicist, Synthesizer)
  - OpenAI (required for Advocate, Futurist)
  - Google/Gemini (required for Skeptic, Pragmatist)
  - Perplexity (required for Fact Checker)

## Environment Variables

Create a `.env` file (never commit this to version control):

```bash
# Required - at least one provider needed
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=AI...
PERPLEXITY_API_KEY=pplx-...

# Phoenix secret (generate with: mix phx.gen.secret)
SECRET_KEY_BASE=your-64-char-secret-key

# Production host
PHX_HOST=yourdomain.com

# Database URL (if adding persistence later)
# DATABASE_URL=<your-database-connection-string>

# Optional
PORT=4000
POOL_SIZE=10
```

## Deployment Options

### Option 1: Fly.io (Recommended)

1. Install flyctl:
   ```bash
   brew install flyctl
   ```

2. Launch the app:
   ```bash
   fly launch
   ```

3. Set secrets:
   ```bash
   fly secrets set ANTHROPIC_API_KEY=sk-ant-...
   fly secrets set OPENAI_API_KEY=sk-...
   fly secrets set GEMINI_API_KEY=AI...
   fly secrets set PERPLEXITY_API_KEY=pplx-...
   fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
   ```

4. Deploy:
   ```bash
   fly deploy
   ```

### Option 2: Docker

1. Build the Docker image:
   ```bash
   docker build -t nervous_system .
   ```

2. Run the container:
   ```bash
   docker run -d \
     -p 4000:4000 \
     -e ANTHROPIC_API_KEY=sk-ant-... \
     -e OPENAI_API_KEY=sk-... \
     -e GEMINI_API_KEY=AI... \
     -e PERPLEXITY_API_KEY=pplx-... \
     -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
     -e PHX_HOST=localhost \
     nervous_system
   ```

### Option 3: Traditional Server (Ubuntu/Debian)

1. Install dependencies:
   ```bash
   # Install ASDF (or use native packages)
   git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
   source ~/.asdf/asdf.sh

   # Install Erlang and Elixir
   asdf plugin add erlang
   asdf plugin add elixir
   asdf install erlang 26.2
   asdf install elixir 1.16.0
   ```

2. Clone and build:
   ```bash
   git clone https://github.com/brannonlucas/elixir-agent-system.git
   cd elixir-agent-system

   export MIX_ENV=prod
   mix deps.get --only prod
   mix compile
   mix assets.deploy
   mix release
   ```

3. Configure systemd service (`/etc/systemd/system/nervous_system.service`):
   ```ini
   [Unit]
   Description=NervousSystem
   After=network.target

   [Service]
   Type=simple
   User=deploy
   Group=deploy
   WorkingDirectory=/opt/nervous_system
   ExecStart=/opt/nervous_system/_build/prod/rel/nervous_system/bin/nervous_system start
   ExecStop=/opt/nervous_system/_build/prod/rel/nervous_system/bin/nervous_system stop
   Restart=on-failure
   RestartSec=5
   Environment=HOME=/opt/nervous_system
   EnvironmentFile=/opt/nervous_system/.env

   [Install]
   WantedBy=multi-user.target
   ```

4. Start the service:
   ```bash
   sudo systemctl enable nervous_system
   sudo systemctl start nervous_system
   ```

## Production Configuration

### SSL/TLS

Configure your reverse proxy (nginx, Caddy) to handle SSL termination:

**Nginx example:**
```nginx
server {
    listen 443 ssl http2;
    server_name yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Important:** WebSocket support is required for LiveView. Ensure `Upgrade` and `Connection` headers are properly proxied.

### Health Checks

The application exposes health endpoints through Phoenix:

- `GET /` - Returns 200 if the application is running

For container orchestration, configure liveness/readiness probes:

```yaml
livenessProbe:
  httpGet:
    path: /
    port: 4000
  initialDelaySeconds: 30
  periodSeconds: 10
```

## Monitoring

### Telemetry

The application includes Phoenix Telemetry. To export metrics:

1. Add a telemetry reporter (e.g., Prometheus):
   ```elixir
   # In config/prod.exs
   config :nervous_system, NervousSystemWeb.Telemetry,
     metrics: [
       # Add your metrics reporters
     ]
   ```

### Logging

Logs are output to stdout by default. In production:

```elixir
# In config/prod.exs
config :logger, level: :info
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
```

For structured logging (JSON), consider adding `logger_json`.

## Scaling Considerations

### Memory

Each deliberation room maintains state in memory:
- ~100KB per room baseline
- ~10KB per agent response in memory
- Rooms are ephemeral (lost on restart)

For high-traffic deployments, consider:
- Adding persistence (PostgreSQL/Redis)
- Implementing room cleanup after inactivity
- Using distributed Erlang for multi-node deployments

### Concurrent Deliberations

The current architecture supports many concurrent rooms:
- Each room is a separate GenServer process
- Agents stream responses independently
- PubSub handles real-time updates efficiently

Estimated capacity per 1GB RAM: ~100 concurrent active deliberations.

## Troubleshooting

### Common Issues

1. **WebSocket connection fails**
   - Ensure proxy forwards `Upgrade` and `Connection` headers
   - Check `PHX_HOST` matches your domain

2. **API key errors**
   - Verify environment variables are set correctly
   - Check provider API quotas and rate limits

3. **High memory usage**
   - Implement room cleanup for idle rooms
   - Monitor for memory leaks in long-running deliberations

4. **Slow responses**
   - API providers may throttle requests
   - Consider implementing request queuing
   - Check network latency to API endpoints

### Debug Mode

Enable debug logging temporarily:

```bash
export LOG_LEVEL=debug
./bin/nervous_system start
```

## Backup and Recovery

Since rooms are currently ephemeral:
- No database backups needed
- Session state is lost on restart
- Consider adding persistence for production use

## Security Checklist

- [ ] API keys stored in environment variables, not in code
- [ ] `.env` file excluded from version control
- [ ] SSL/TLS enabled for all traffic
- [ ] `SECRET_KEY_BASE` is unique and secure (64+ characters)
- [ ] Force SSL in production (`config :nervous_system, NervousSystemWeb.Endpoint, force_ssl: true`)
- [ ] Rate limiting configured (if exposed publicly)
- [ ] Monitor for unusual API usage patterns

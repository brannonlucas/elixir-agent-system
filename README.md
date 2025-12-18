# NervousSystem

A multi-agent AI deliberation platform built with Phoenix LiveView. NervousSystem orchestrates conversations between multiple AI agents, each with distinct personalities and potentially backed by different LLM providers, to explore topics from diverse perspectives.

## Overview

NervousSystem implements a "facilitated roundtable" pattern where:

- **9 specialized agents** with distinct personalities deliberate on user topics
- **4 LLM providers** (Anthropic, OpenAI, Google, Perplexity) can power different agents
- **Structured phases** guide discussions from framework → discussion → synthesis
- **Real-time streaming** via Phoenix LiveView delivers agent responses as they're generated
- **Quality evaluation** scores deliberations across 8 dimensions

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Room (GenServer)                        │
│  Orchestrates deliberation: phases, turn-taking, broadcasting   │
└─────────────────────────────────────────────────────────────────┘
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
              ┌─────────┐   ┌─────────┐   ┌─────────┐
              │  Agent  │   │  Agent  │   │  Agent  │  ... (9 agents)
              │ Analyst │   │Advocate │   │ Skeptic │
              └────┬────┘   └────┬────┘   └────┬────┘
                   │             │             │
                   ▼             ▼             ▼
              ┌─────────┐   ┌─────────┐   ┌─────────┐
              │Anthropic│   │ OpenAI  │   │ Google  │  ... (4 providers)
              └─────────┘   └─────────┘   └─────────┘
```

### Core Modules

| Module | Purpose |
|--------|---------|
| `NervousSystem.Room` | GenServer orchestrating multi-agent deliberations |
| `NervousSystem.Agent` | GenServer representing an AI agent with personality |
| `NervousSystem.Provider` | Behaviour defining the LLM provider contract |
| `NervousSystem.Evaluator` | Scores deliberation quality across 8 dimensions |

### Agent Personalities

Each agent brings a unique perspective to deliberations:

| Personality | Role | Focus |
|-------------|------|-------|
| **Analyst** | Evidence-focused | Data, studies, quantification |
| **Advocate** | Optimistic explorer | Benefits, opportunities, success stories |
| **Skeptic** | Critical thinker | Risks, assumptions, failure modes |
| **Historian** | Context provider | Historical parallels, precedents, lessons |
| **Futurist** | Trend extrapolator | Projections, scenarios, emerging shifts |
| **Pragmatist** | Implementation focus | Feasibility, next steps, constraints |
| **Ethicist** | Moral examiner | Fairness, rights, who benefits/is harmed |
| **Synthesizer** | Integrator | Common ground, trade-offs, conclusions |
| **Fact Checker** | Verifier (async) | Claim verification with sources |

### LLM Providers

| Provider | Default Model | Use Case |
|----------|---------------|----------|
| Anthropic | `claude-sonnet-4-20250514` | Primary deliberation |
| OpenAI | `gpt-4o` | Alternative perspective |
| Google | `gemini-2.0-flash` | Fast responses |
| Perplexity | `sonar` | Web-grounded fact checking |

## Getting Started

### Prerequisites

- Elixir ~> 1.15
- Erlang/OTP (compatible with Elixir version)

### Environment Variables

Create a `.env` file or export these variables:

```bash
# Required: At least one provider API key
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
export GEMINI_API_KEY="..."
export PERPLEXITY_API_KEY="pplx-..."

# Production only
export SECRET_KEY_BASE="..."  # Generate with: mix phx.gen.secret
export PHX_HOST="your-domain.com"
export PORT="4000"
```

### Installation

```bash
# Install dependencies
mix setup

# Start the server
mix phx.server

# Or start with IEx for debugging
iex -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) to start a deliberation.

## Discussion Phases

1. **Framework** (max 4 turns) - Agents establish the analytical framework
2. **Discussion** (max 18 turns) - Facilitated roundtable with turn nominations
3. **Synthesis** - Synthesizer integrates perspectives into actionable conclusions

Agents nominate who speaks next ("I'd like to hear from [Agent1] and [Agent2]"), creating organic conversation flow.

## Quality Evaluation

After synthesis, the Evaluator scores deliberations (0-10) across:

- **Engagement** - Did agents respond to each other?
- **Evidence** - Were claims backed by data/sources?
- **Diversity** - Did agents genuinely disagree?
- **Context Integration** - Did agents address user's situation?
- **Actionability** - Were concrete next steps provided?
- **Synthesis** - Did synthesis capture the discussion?
- **Fact Checking** - Were claims verified?
- **Conciseness** - Did agents stay focused?

## Development

```bash
# Run tests
mix test

# Run precommit checks (compile warnings, format, test)
mix precommit

# Format code
mix format
```

## Project Structure

```
lib/
├── nervous_system/
│   ├── agent.ex           # Agent GenServer with personalities
│   ├── application.ex     # OTP application supervisor
│   ├── evaluator.ex       # Discussion quality scoring
│   ├── provider.ex        # LLM provider behaviour
│   ├── providers/
│   │   ├── anthropic.ex   # Claude API
│   │   ├── google.ex      # Gemini API
│   │   ├── openai.ex      # GPT API
│   │   └── perplexity.ex  # Sonar API (web search)
│   └── room.ex            # Deliberation orchestration
└── nervous_system_web/
    ├── live/
    │   └── room_live.ex   # LiveView for real-time UI
    └── ...
```

## License

[Add your license here]

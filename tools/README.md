# Local Development Tools

This directory contains utilities for running and managing the voice agent application locally.

## Available Tools

### `run_local_simple.ps1`
A PowerShell script that provides a simple way to run the application with dependency checks.

**Usage:**
```powershell
# Basic usage (default port 3000)
.\tools\run_local_simple.ps1

# Use a different port
.\tools\run_local_simple.ps1 -Port 3001

# Skip dependency checks
.\tools\run_local_simple.ps1 -SkipDependencies

# Skip Python search service check
.\tools\run_local_simple.ps1 -SkipPySearch
```

**Features:**
- Checks for Node.js/npm installation
- Verifies port availability
- Checks optional dependencies (PostgreSQL, Redis, Python search)
- Loads environment variables from `.env` file
- Provides clear status messages

### `run_local.cmd`
A simple batch file for Windows CMD users.

**Usage:**
```cmd
cd tools
run_local.cmd
```

**Features:**
- Basic Node.js/npm checks
- Port availability warning
- Simple error handling

## Prerequisites

1. **Node.js** (v16+ recommended) - includes npm
2. **.env file** - should be in project root with required configuration
3. **Optional dependencies** (for full functionality):
   - PostgreSQL (port 5432 by default)
   - Redis (port 6379 by default)
   - Python search service (port 5051 by default)

## Quick Start

1. Ensure you have Node.js installed
2. Copy `.env.example` to `.env` and configure your settings
3. Run the application:

```powershell
# PowerShell (recommended)
.\tools\run_local_simple.ps1

# Or CMD
cd tools
run_local.cmd
```

## Troubleshooting

### Port already in use
- Change the `PORT` value in your `.env` file
- Or use `-Port` parameter: `.\tools\run_local_simple.ps1 -Port 3001`

### Missing dependencies
The application can run without PostgreSQL/Redis/Python search, but some features will be limited:
- Voice agent functionality requires OpenAI API key in `.env`
- Database features require PostgreSQL
- Caching features require Redis
- Search features require Python search service

### Node.js not found
- Download and install Node.js from https://nodejs.org/
- Ensure Node.js is in your PATH

## Related Tools

See other tools in this directory for deployment, configuration, and maintenance tasks.
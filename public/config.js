// Centralized configuration using convict
import convict from 'convict';
import dotenv from 'dotenv';

// Load environment variables from .env file
dotenv.config();

// Define the configuration schema
const config = convict({
  env: {
    doc: 'The application environment.',
    format: ['development', 'production', 'test'],
    default: 'development',
    env: 'NODE_ENV'
  },
  server: {
    port: {
      doc: 'Server port',
      format: 'port',
      default: 3000,
      env: 'PORT'
    }
  },

  admin: {
    apiKey: {
      doc: 'Admin API key for protected endpoints',
      format: String,
      default: '',
      env: 'ADMIN_API_KEY',
      sensitive: true
    }
  },
  openai: {
    apiKey: {
      doc: 'OpenAI API key',
      format: String,
      default: '',
      env: 'OPENAI_API_KEY',
      sensitive: true
    },
    model: {
      doc: 'OpenAI model name',
      format: String,
      default: 'gpt-realtime-mini',
      env: 'MODEL_NAME'
    },
    voice: {
      doc: 'OpenAI voice ID',
      format: String,
      default: 'ash',
      env: 'VOICE_ID'
    },
    mock: {
      doc: 'Use mock OpenAI session data',
      format: Boolean,
      default: false,
      env: 'MOCK_OPENAI'
    }
  },
  database: {
    url: {
      doc: 'Database connection URL',
      format: String,
      default: 'postgres://postgres:postgres@localhost:5432/db',
      env: 'DATABASE_URL'
    }
  }
});

// Validate configuration and export
config.validate({ allowed: 'strict' });

export default config; // Используем export default для ESM

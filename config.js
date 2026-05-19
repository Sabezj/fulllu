// Centralized configuration using convict
import convict from 'convict';
const isNode = typeof window === 'undefined';

if (isNode) {
  // ❶ читаем .env только на сервере / в CLI-воркерах
  await import('dotenv').then(({ config }) => config());
}

// ❷ забираем переменные из process.env — в браузере
//     их подставит DefinePlugin / Vite / ваша сборка из CI.

// Load environment variables from .env file

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
  commerce: {
    catalogEnabled: {
      doc: 'Enable legacy commerce product catalog/search endpoints',
      format: Boolean,
      default: false,
      env: 'ENABLE_COMMERCE_CATALOG'
    }
  },
  auth: {
    devNoAuth: {
      doc: 'Disable JWT for development environments',
      format: Boolean,
      default: process.env.NODE_ENV === 'development',
      env: 'DEV_NO_AUTH'
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
    intentModel: {
      doc: 'Model used for intent classification',
      format: String,
      default: 'gpt-4o-mini',
      env: 'INTENT_MODEL'
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
      default: 'postgres://postgres:pass@localhost:5432/db',
      env: 'DATABASE_URL'
    }
  }
});

// Validate configuration and export
config.validate({ allowed: 'strict' });

export default config; // Используем export default для ESM

module.exports = {
  apps: [
    {
      name: 'allaw-urist.ru',
      script: './server.js',
      cwd: __dirname,
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '768M',
      env: {
        NODE_ENV: 'production'
      }
    }
  ]
};

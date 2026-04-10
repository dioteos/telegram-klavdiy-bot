const os = require('os');
const path = require('path');

const home = os.homedir();

module.exports = {
  apps: [
    {
      name: 'telegram-klavdiy',
      script: path.join(__dirname, 'start.sh'),
      interpreter: '/bin/bash',
      cwd: __dirname,
      autorestart: true,
      min_uptime: 60000,
      max_restarts: 50,
      exp_backoff_restart_delay: 60000,
      max_memory_restart: '512M',
      cron_restart: '0 4,16 * * *',
      env: {
        HOME: home,
      },
    },
    {
      name: 'telegram-watchdog',
      script: path.join(__dirname, 'watchdog.sh'),
      interpreter: '/bin/bash',
      cwd: __dirname,
      autorestart: true,
      min_uptime: 10000,
      max_restarts: 10,
      env: {
        HOME: home,
      },
    },
  ],
};

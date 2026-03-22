const os = require('os');
const path = require('path');

const home = os.homedir();

module.exports = {
  apps: [{
    name: 'telegram-klavdiy',
    script: path.join(__dirname, 'start.sh'),
    interpreter: '/bin/bash',
    cwd: __dirname,
    autorestart: true,
    min_uptime: 60000,
    max_restarts: 50,
    restart_delay: 30000,
    exp_backoff_restart_delay: 60000,
    max_memory_restart: '512M',
    cron_restart: '0 4 * * *',
    env: {
      HOME: home,
    },
  }],
};

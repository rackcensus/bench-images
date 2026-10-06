<?php
define( 'DB_NAME', 'woocommerce' );
define( 'DB_USER', 'woo' );
define( 'DB_PASSWORD', 'woo' );
define( 'DB_HOST', 'woo-db' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

require __DIR__ . '/wp-salts.php';

$table_prefix = 'wp_';

define( 'WP_HOME', 'http://woo' );
define( 'WP_SITEURL', 'http://woo' );
define( 'WP_ENVIRONMENT_TYPE', 'production' );
define( 'WP_DEBUG', false );
define( 'WP_CACHE', false );
define( 'DISABLE_WP_CRON', true );
define( 'WP_HTTP_BLOCK_EXTERNAL', true );
define( 'AUTOMATIC_UPDATER_DISABLED', true );
define( 'DISALLOW_FILE_MODS', true );

if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';

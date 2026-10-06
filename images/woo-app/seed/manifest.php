<?php
$home     = untrailingslashit( home_url() );
$relative = static function ( string $url ) use ( $home ): string {
	return 0 === strpos( $url, $home ) ? substr( $url, strlen( $home ) ) : $url;
};

$cart_ids = array();
foreach ( wc_get_products( array( 'status' => 'publish', 'type' => 'simple', 'limit' => -1, 'orderby' => 'ID', 'order' => 'ASC' ) ) as $product ) {
	if ( $product->is_purchasable() && $product->is_in_stock() && 'visible' === $product->get_catalog_visibility() ) {
		$cart_ids[] = $product->get_id();
	}
}

$product_paths = array();
foreach ( wc_get_products( array( 'status' => 'publish', 'limit' => -1, 'orderby' => 'ID', 'order' => 'ASC' ) ) as $product ) {
	if ( 'visible' === $product->get_catalog_visibility() ) {
		$product_paths[] = $relative( get_permalink( $product->get_id() ) );
	}
}

$category_paths = array();
$default_cat    = (int) get_option( 'default_product_cat' );
foreach ( get_terms( array( 'taxonomy' => 'product_cat', 'hide_empty' => true, 'orderby' => 'term_id' ) ) as $term ) {
	if ( (int) $term->term_id !== $default_cat ) {
		$category_paths[] = $relative( get_term_link( $term ) );
	}
}

$search_terms = array();
foreach ( array( 'hoodie', 'shirt', 'tee', 'beanie', 'logo', 'album', 'music', 'cotton', 'pocket', 'sunglasses' ) as $term ) {
	$query = new WP_Query( array( 'post_type' => 'product', 'post_status' => 'publish', 's' => $term, 'fields' => 'ids', 'posts_per_page' => 1 ) );
	if ( $query->found_posts >= 2 ) {
		$search_terms[] = $term;
	}
}

$theme = wp_get_theme();
echo wp_json_encode(
	array(
		'product_ids'    => $cart_ids,
		'product_paths'  => $product_paths,
		'category_paths' => $category_paths,
		'search_terms'   => $search_terms,
		'pages'          => array(
			'home'     => $relative( trailingslashit( home_url() ) ),
			'shop'     => $relative( get_permalink( wc_get_page_id( 'shop' ) ) ),
			'cart'     => $relative( get_permalink( wc_get_page_id( 'cart' ) ) ),
			'checkout' => $relative( get_permalink( wc_get_page_id( 'checkout' ) ) ),
		),
		'versions'       => array(
			'wordpress'   => get_bloginfo( 'version' ),
			'woocommerce' => WC()->version,
			'theme'       => $theme->get_stylesheet() . ' ' . $theme->get( 'Version' ),
			'php'         => PHP_VERSION,
		),
	),
	JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES
) . "\n";

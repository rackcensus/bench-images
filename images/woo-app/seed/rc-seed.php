<?php
add_filter(
	'pre_http_request',
	static function ( $pre, $args, $url ) {
		$local = '/seed/images/' . sha1( $url );
		if ( ! is_file( $local ) ) {
			return $pre;
		}
		$info = getimagesize( $local );
		$body = '';
		if ( ! empty( $args['stream'] ) && ! empty( $args['filename'] ) ) {
			copy( $local, $args['filename'] );
		} else {
			$body = file_get_contents( $local );
		}
		return array(
			'headers'  => array(
				'content-type'   => $info ? $info['mime'] : 'application/octet-stream',
				'content-length' => (string) filesize( $local ),
			),
			'body'     => $body,
			'response' => array(
				'code'    => 200,
				'message' => 'OK',
			),
			'cookies'  => array(),
			'filename' => $args['filename'] ?? null,
		);
	},
	10,
	3
);

add_filter( 'pre_wp_mail', '__return_false' );

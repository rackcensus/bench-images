<?php
[, $xml_path, $dir] = $argv;

preg_match_all( '#<wp:attachment_url>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</wp:attachment_url>#', file_get_contents( $xml_path ), $matches );
$urls = array_values( array_unique( $matches[1] ) );
if ( ! $urls ) {
	fwrite( STDERR, "no attachment urls found in $xml_path\n" );
	exit( 1 );
}

if ( ! is_dir( $dir ) && ! mkdir( $dir, 0755, true ) ) {
	exit( 1 );
}

function fetch_image( string $url ): ?string {
	for ( $attempt = 1; $attempt <= 3; $attempt++ ) {
		$ch = curl_init( $url );
		curl_setopt_array(
			$ch,
			array(
				CURLOPT_RETURNTRANSFER => true,
				CURLOPT_FOLLOWLOCATION => true,
				CURLOPT_CONNECTTIMEOUT => 10,
				CURLOPT_TIMEOUT        => 30,
				CURLOPT_USERAGENT      => 'rackcensus-bench-images',
			)
		);
		$body = curl_exec( $ch );
		$code = curl_getinfo( $ch, CURLINFO_RESPONSE_CODE );
		if ( false !== $body && 200 === $code && false !== @getimagesizefromstring( $body ) ) {
			return $body;
		}
		if ( in_array( $code, array( 403, 404, 410 ), true ) ) {
			return null;
		}
		sleep( $attempt * 2 );
	}
	return null;
}

function placeholder_image( string $url ): string {
	mt_srand( crc32( $url ) );
	$size  = 800;
	$image = imagecreatetruecolor( $size, $size );
	$base  = array( mt_rand( 60, 200 ), mt_rand( 60, 200 ), mt_rand( 60, 200 ) );
	for ( $y = 0; $y < $size; $y += 2 ) {
		for ( $x = 0; $x < $size; $x += 2 ) {
			$shade = (int) ( 40 * sin( ( $x + $y ) / 90 ) ) + mt_rand( -18, 18 );
			$color = imagecolorallocate(
				$image,
				max( 0, min( 255, $base[0] + $shade ) ),
				max( 0, min( 255, $base[1] + $shade ) ),
				max( 0, min( 255, $base[2] + $shade ) )
			);
			imagefilledrectangle( $image, $x, $y, $x + 1, $y + 1, $color );
		}
	}
	ob_start();
	imagejpeg( $image, null, 82 );
	return ob_get_clean();
}

$fetched      = 0;
$placeholders = 0;
$index        = array();
foreach ( $urls as $url ) {
	$body        = fetch_image( $url );
	$placeholder = null === $body;
	if ( $placeholder ) {
		fwrite( STDERR, "could not fetch $url, using a generated placeholder\n" );
		$body = placeholder_image( $url );
		++$placeholders;
	} else {
		++$fetched;
	}
	$file = sha1( $url );
	file_put_contents( "$dir/$file", $body );
	$index[ $url ] = array(
		'file'        => $file,
		'bytes'       => strlen( $body ),
		'sha256'      => hash( 'sha256', $body ),
		'placeholder' => $placeholder,
	);
}

file_put_contents( "$dir/index.json", json_encode( $index, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES ) . "\n" );
printf( "sample images: fetched %d of %d, generated %d placeholders\n", $fetched, count( $urls ), $placeholders );

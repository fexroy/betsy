#version 430 core

// #include "/media/matias/Datos/SyntaxHighlightingMisc.h"

#include "CrossPlatformSettings_piece_all.glsl"
#include "UavCrossPlatform_piece_all.glsl"

#define FLT_MAX 340282346638528859811704183484516925440.0f

#define TODO_check_if_colour_equal

uniform uint p_numRefinements;

uniform sampler2D srcTex;

layout( rg32ui ) uniform restrict writeonly uimage2D dstTexture;

layout( std430, binding = 1 ) readonly restrict buffer globalBuffer
{
	float2 c_oMatch5[256];
	float2 c_oMatch6[256];
};

layout( local_size_x = 8,  //
		local_size_y = 8,  //
		local_size_z = 1 ) in;

float3 rgb565to888( float rgb565 )
{
	float3 retVal;
	retVal.x = floor( rgb565 / 2048.0f );
	retVal.y = floor( mod( rgb565, 2048.0f ) / 32.0f );
	retVal.z = floor( mod( rgb565, 32.0f ) );

	return floor( retVal * ( 255.0f / float3( 31.0f, 63.0f, 31.0f ) ) + 0.5f );
}

float rgb888to565( float3 rgbValue )
{
	rgbValue.rb = floor( rgbValue.rb * 31.0f / 255.0f + 0.5f );
	rgbValue.g = floor( rgbValue.g * 63.0f / 255.0f + 0.5f );

	return rgbValue.r * 2048.0f + rgbValue.g * 32.0f + rgbValue.b;
}

// linear interpolation at 1/3 point between a and b, using desired rounding type
float3 lerp13( float3 a, float3 b )
{
#ifdef STB_DXT_USE_ROUNDING_BIAS
	// with rounding bias
	return a + floor( ( b - a ) * ( 1.0f / 3.0f ) + 0.5f );
#else
	// without rounding bias
	return floor( ( 2.0f * a + b ) / 3.0f );
#endif
}

/// Unpacks a block of 4 colours from two 16-bit endpoints
void EvalColors( out float3 colours[4], float c0, float c1 )
{
	colours[0] = rgb565to888( c0 );
	colours[1] = rgb565to888( c1 );
	colours[2] = lerp13( colours[0], colours[1] );
	colours[3] = lerp13( colours[1], colours[0] );
}

/** The color optimization function. (Clever code, part 1)
@param outMinEndp16 [out]
	Minimum endpoint, in RGB565
@param outMaxEndp16 [out]
	Maximum endpoint, in RGB565
*/
void OptimizeColorsBlock( const uint srcPixelsBlock[16], out float outMinEndp16, out float outMaxEndp16 )
{
	// determine color distribution
	float3 avgColour;
	float3 minColour;
	float3 maxColour;

	avgColour = minColour = maxColour = unpackUnorm4x8( srcPixelsBlock[0] ).xyz;
	for( int i = 1; i < 16; ++i )
	{
		const float3 currColourUnorm = unpackUnorm4x8( srcPixelsBlock[i] ).xyz;
		avgColour += currColourUnorm;
		minColour = min( minColour, currColourUnorm );
		maxColour = max( maxColour, currColourUnorm );
	}

	avgColour = round( avgColour * 255.0f / 16.0f );
	maxColour *= 255.0f;
	minColour *= 255.0f;

	// determine covariance matrix
	float cov[6];
	for( int i = 0; i < 6; ++i )
		cov[i] = 0;

	for( int i = 0; i < 16; ++i )
	{
		const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;
		float3 rgbDiff = currColour - avgColour;

		cov[0] += rgbDiff.r * rgbDiff.r;
		cov[1] += rgbDiff.r * rgbDiff.g;
		cov[2] += rgbDiff.r * rgbDiff.b;
		cov[3] += rgbDiff.g * rgbDiff.g;
		cov[4] += rgbDiff.g * rgbDiff.b;
		cov[5] += rgbDiff.b * rgbDiff.b;
	}

	// convert covariance matrix to float, find principal axis via power iter
	for( int i = 0; i < 6; ++i )
		cov[i] /= 255.0f;

	float3 vF = maxColour - minColour;

	const int nIterPower = 4;
	for( int iter = 0; iter < nIterPower; ++iter )
	{
		const float r = vF.r * cov[0] + vF.g * cov[1] + vF.b * cov[2];
		const float g = vF.r * cov[1] + vF.g * cov[3] + vF.b * cov[4];
		const float b = vF.r * cov[2] + vF.g * cov[4] + vF.b * cov[5];

		vF.r = r;
		vF.g = g;
		vF.b = b;
	}

	float magn = max3( abs( vF.r ), abs( vF.g ), abs( vF.b ) );
	float3 v;

	if( magn < 4.0f )
	{                  // too small, default to luminance
		v.r = 299.0f;  // JPEG YCbCr luma coefs, scaled by 1000.
		v.g = 587.0f;
		v.b = 114.0f;
	}
	else
	{
		v = trunc( vF * ( 512.0f / magn ) );
	}

	// Pick colors at extreme points
	float3 minEndpoint, maxEndpoint;
	float minDot = FLT_MAX;
	float maxDot = -FLT_MAX;
	for( int i = 0; i < 16; ++i )
	{
		const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;
		const float dotValue = dot( currColour, v );

		if( dotValue < minDot )
		{
			minDot = dotValue;
			minEndpoint = currColour;
		}

		if( dotValue > maxDot )
		{
			maxDot = dotValue;
			maxEndpoint = currColour;
		}
	}

	outMinEndp16 = rgb888to565( minEndpoint );
	outMaxEndp16 = rgb888to565( maxEndpoint );
}

// The color matching function
uint MatchColorsBlock( const uint srcPixelsBlock[16], float3 colour[4] )
{
	uint mask = 0u;
	float3 dir = colour[0] - colour[1];
	float stops[4];

	for( int i = 0; i < 4; ++i )
		stops[i] = dot( colour[i], dir );

	// think of the colors as arranged on a line; project point onto that line, then choose
	// next color out of available ones. we compute the crossover points for "best color in top
	// half"/"best in bottom half" and then the same inside that subinterval.
	//
	// relying on this 1d approximation isn't always optimal in terms of euclidean distance,
	// but it's very close and a lot faster.
	// http://cbloomrants.blogspot.com/2008/12/12-08-08-dxtc-summary.html

	float c0Point = trunc( ( stops[1] + stops[3] ) * 0.5f );
	float halfPoint = trunc( ( stops[3] + stops[2] ) * 0.5f );
	float c3Point = trunc( ( stops[2] + stops[0] ) * 0.5f );

#ifndef BC1_DITHER
	// the version without dithering is straightforward
	for( uint i = 16u; i-- > 0u; )
	{
		const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;

		const float dotValue = dot( currColour, dir );
		mask <<= 2u;

		if( dotValue < halfPoint )
			mask |= ( ( dotValue < c0Point ) ? 1u : 3u );
		else
			mask |= ( ( dotValue < c3Point ) ? 2u : 0u );
	}
#else
	// with floyd-steinberg dithering
	float4 ep1 = float4( 0, 0, 0, 0 );
	float4 ep2 = float4( 0, 0, 0, 0 );

	c0Point *= 16.0f;
	halfPoint *= 16.0f;
	c3Point *= 16.0f;

	for( uint y = 0u; y < 4u; ++y )
	{
		float ditherDot;
		uint lmask, step;

		float3 currColour;
		float dotValue;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4 + 0] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 3 * ep2[1] + 5 * ep2[0] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[0] = dotValue - stops[step];
		lmask = step;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4 + 1] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 7 * ep1[0] + 3 * ep2[2] + 5 * ep2[1] + ep2[0] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[1] = dotValue - stops[step];
		lmask |= step << 2u;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4 + 2] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 7 * ep1[1] + 3 * ep2[3] + 5 * ep2[2] + ep2[1] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[2] = dotValue - stops[step];
		lmask |= step << 4u;

		currColour = unpackUnorm4x8( srcPixelsBlock[y * 4 + 2] ).xyz * 255.0f;
		dotValue = dot( currColour, dir );

		ditherDot = ( dotValue * 16.0f ) + ( 7 * ep1[2] + 5 * ep2[3] + ep2[2] );
		if( ditherDot < halfPoint )
			step = ( ditherDot < c0Point ) ? 1u : 3u;
		else
			step = ( ditherDot < c3Point ) ? 2u : 0u;
		ep1[3] = dotValue - stops[step];
		lmask |= step << 6u;

		mask |= lmask << ( y * 8u );
		{
			float4 tmp = ep1;
			ep1 = ep2;
			ep2 = tmp;
		}  // swap
	}
#endif

	return mask;
}

// The refinement function. (Clever code, part 2)
// Tries to optimize colors to suit block contents better.
// (By solving a least squares system via normal equations+Cramer's rule)
bool RefineBlock( const uint srcPixelsBlock[16], uint mask, inout float inOutMinEndp16,
				  inout float inOutMaxEndp16 )
{
	float newMin16, newMax16;
	const float oldMin = inOutMinEndp16;
	const float oldMax = inOutMaxEndp16;

	if( ( mask ^ ( mask << 2u ) ) < 4u )  // all pixels have the same index?
	{
		// yes, linear system would be singular; solve using optimal
		// single-color match on average color
		float3 rgbVal = float3( 8.0f / 255.0f, 8.0f / 255.0f, 8.0f / 255.0f );
		for( int i = 0; i < 16; ++i )
			rgbVal += unpackUnorm4x8( srcPixelsBlock[i] ).xyz;

		rgbVal = floor( rgbVal * ( 255.0f / 16.0f ) );

		newMax16 = c_oMatch5[uint( rgbVal.r )][0] * 2048.0f +  //
				   c_oMatch6[uint( rgbVal.g )][0] * 32.0f +    //
				   c_oMatch5[uint( rgbVal.b )][0];
		newMin16 = c_oMatch5[uint( rgbVal.r )][1] * 2048.0f +  //
				   c_oMatch6[uint( rgbVal.g )][1] * 32.0f +    //
				   c_oMatch5[uint( rgbVal.b )][1];
	}
	else
	{
		const float w1Tab[4] = { 3, 0, 2, 1 };
		const float prods[4] = { 589824.0f, 2304.0f, 262402.0f, 66562.0f };
		// ^some magic to save a lot of multiplies in the accumulating loop...
		// (precomputed products of weights for least squares system, accumulated inside one 32-bit
		// register)

		float akku = 0.0f;
		uint cm = mask;
		float3 at1 = float3( 0, 0, 0 );
		float3 at2 = float3( 0, 0, 0 );
		for( int i = 0; i < 16; ++i, cm >>= 2u )
		{
			const float3 currColour = unpackUnorm4x8( srcPixelsBlock[i] ).xyz * 255.0f;

			const uint step = cm & 3u;
			const float w1 = w1Tab[step];
			akku += prods[step];
			at1 += currColour * w1;
			at2 += currColour;
		}

		at2 = 3.0f * at2 - at1;

		// extract solutions and decide solvability
		const float xx = floor( akku / 65535.0f );
		const float yy = floor( mod( akku, 65535.0f ) / 256.0f );
		const float xy = mod( akku, 256.0f );

		float2 f_rb_g;
		f_rb_g.x = 3.0f * 31.0f / 255.0f / ( xx * yy - xy * xy );
		f_rb_g.y = f_rb_g.x * 63.0f / 31.0f;

		// solve.
		const float3 newMaxVal = clamp( floor( ( at1 * yy - at2 * xy ) * f_rb_g.xyx + 0.5f ),
										float3( 0.0f, 0.0f, 0.0f ), float3( 31, 63, 31 ) );
		newMax16 = newMaxVal.x * 2048.0f + newMaxVal.y * 32.0f + newMaxVal.z;

		const float3 newMinVal = clamp( floor( ( at2 * xx - at1 * xy ) * f_rb_g.xyx + 0.5f ),
										float3( 0.0f, 0.0f, 0.0f ), float3( 31, 63, 31 ) );
		newMin16 = newMinVal.x * 2048.0f + newMinVal.y * 32.0f + newMinVal.z;
	}

	inOutMinEndp16 = newMin16;
	inOutMaxEndp16 = newMax16;

	return oldMin != newMin16 || oldMax != newMax16;
}

void main()
{
	uint srcPixelsBlock[16];

	// Load the whole 4x4 block
	const uint2 pixelsToLoadBase = gl_GlobalInvocationID.xy << 2u;
	for( uint i = 0u; i < 16u; ++i )
	{
		const uint2 pixelsToLoad = pixelsToLoadBase + uint2( i & 0x03u, i >> 2u );
		const float3 srcPixels0 = OGRE_Load2D( srcTex, int2( pixelsToLoad ), 0 ).xyz;
		srcPixelsBlock[i] = packUnorm4x8( float4( srcPixels0, 1.0f ) );
	}

	TODO_check_if_colour_equal;

	float maxEndp16, minEndp16;
	uint mask = 0u;

	// second step: pca+map along principal axis
	OptimizeColorsBlock( srcPixelsBlock, minEndp16, maxEndp16 );
	if( minEndp16 != maxEndp16 )
	{
		float3 colours[4];
		EvalColors( colours, maxEndp16, minEndp16 );  // Note min/max are inverted
		mask = MatchColorsBlock( srcPixelsBlock, colours );
	}

	// third step: refine (multiple times if requested)
	bool bStopRefinement = false;
	for( uint i = 0u; i < p_numRefinements && !bStopRefinement; ++i )
	{
		const uint lastMask = mask;

		if( RefineBlock( srcPixelsBlock, mask, minEndp16, maxEndp16 ) )
		{
			if( minEndp16 != maxEndp16 )
			{
				float3 colours[4];
				EvalColors( colours, maxEndp16, minEndp16 );  // Note min/max are inverted
				mask = MatchColorsBlock( srcPixelsBlock, colours );
			}
			else
			{
				mask = 0u;
				bStopRefinement = true;
			}
		}

		bStopRefinement = mask == lastMask || bStopRefinement;
	}

	// write the color block
	if( maxEndp16 < minEndp16 )
	{
		const float tmpValue = minEndp16;
		minEndp16 = maxEndp16;
		maxEndp16 = tmpValue;
		mask ^= 0x55555555u;
	}

	uint2 outputBytes;
	outputBytes.x = uint( maxEndp16 ) | ( uint( minEndp16 ) << 16u );
	outputBytes.y = mask;

	uint2 dstUV = gl_GlobalInvocationID.xy;
	imageStore( dstTexture, int2( dstUV ), uint4( outputBytes.xy, 0u, 0u ) );
}

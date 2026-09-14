<?php

// The runtime probe: everything `platform.zig` needs to know about an
// interpreter, in ONE process.
//
// Why a file rather than a string in the Zig source: the `lib-*` half below is
// a port of Composer's `PlatformRepository::__construct` switch, regex for
// regex. Keeping it as PHP means `php -l` checks it, its output can be diffed
// against `composer show --platform` directly, and the next person to sync it
// with Composer is reading the same language Composer wrote it in.
//
// Probing per requirement would mean one interpreter start each, so a project
// with thirty `ext-` requires would pay thirty PHP startups to answer a
// question the first one already knew.

$ext = [];
foreach (get_loaded_extensions() as $x) {
    if ($x === 'standard' || $x === 'Core') {
        continue;
    }
    $v = phpversion($x);
    $ext['ext-' . str_replace(' ', '-', strtolower($x))] = ($v === false || $v === '') ? '0' : $v;
}

$loaded = array_map('strtolower', get_loaded_extensions());
$lib = [];
$libprov = [];

// ── Composer's Platform\Version helpers ──────────────────────────────────────

/** `strlen($a) * (-ord('a') + 1) + array_sum(array_map('ord', str_split($a)))` */
function ppkg_alpha_to_int(string $alpha): int
{
    if ($alpha === '') {
        return 0;
    }
    return strlen($alpha) * (-ord('a') + 1) + array_sum(array_map('ord', str_split($alpha)));
}

function ppkg_version_id(int $id, int $base): string
{
    return sprintf('%d.%d.%d', intdiv($id, $base * $base), intdiv($id, $base) % $base, $id % $base);
}

function ppkg_parse_openssl(string $text, ?bool &$isFips): ?string
{
    $isFips = false;
    $re = '/^(?<version>[0-9.]+)(?<patch>[a-z]{0,2})(?<suffix>(?:-?(?:dev|pre|alpha|beta|rc|fips)[\d]*)*)(?:-\w+)?(?: \(.+?\))?$/';
    if (!preg_match($re, $text, $m)) {
        return null;
    }
    $patch = '';
    // Before 3.0.0 OpenSSL's patch level was a letter, and Composer turns it
    // into the number that letter stands for.
    if (version_compare($m['version'], '3.0.0', '<')) {
        $patch = '.' . ppkg_alpha_to_int($m['patch'] ?? '');
    }
    $suffix = $m['suffix'] ?? '';
    $isFips = strpos($suffix, 'fips') !== false;
    $suffix = strtr('-' . ltrim($suffix, '-'), ['-fips' => '', '-pre' => '-alpha']);
    return rtrim($m['version'] . $patch . $suffix, '-');
}

function ppkg_parse_libjpeg(string $v): ?string
{
    if (!preg_match('/^(?<major>\d+)(?<minor>[a-z]*)$/', $v, $m)) {
        return null;
    }
    return $m['major'] . '.' . ppkg_alpha_to_int($m['minor'] ?? '');
}

function ppkg_parse_zoneinfo(string $v): ?string
{
    if (!preg_match('/^(?<year>\d{4})(?<revision>[a-z]*)$/', $v, $m)) {
        return null;
    }
    return $m['year'] . '.' . ppkg_alpha_to_int($m['revision'] ?? '');
}

/**
 * `addLibrary`, including its two refusals: a null version contributes nothing,
 * and the FIRST entry for a name wins.
 *
 * `$provides` is recorded SEPARATELY rather than merged into the library map.
 * Both answer "does version X satisfy constraint C" identically — a provided
 * alias carries the provider's version — but only the library map is a list of
 * libraries this machine has. `lib-libxml` provides `lib-dom-libxml`; claiming
 * the latter is installed would be a small lie in every listing.
 */
function ppkg_add(array &$lib, string $name, ?string $version, array $provides = []): void
{
    if ($version === null || $version === '') {
        return;
    }
    if (isset($lib['lib-' . $name])) {
        return;
    }
    $lib['lib-' . $name] = $version;

    global $libprov;
    foreach ($provides as $key) {
        if (!isset($libprov['lib-' . $key]) && !isset($lib['lib-' . $key])) {
            $libprov['lib-' . $key] = $version;
        }
    }
}

function ppkg_info(string $extension): string
{
    try {
        $reflector = new ReflectionExtension($extension);
    } catch (Throwable $e) {
        return '';
    }
    ob_start();
    $reflector->info();
    return (string) ob_get_clean();
}

// ── the switch, ported from PlatformRepository ───────────────────────────────

foreach ($loaded as $name) {
    switch ($name) {
        case 'amqp':
            $info = ppkg_info($name);
            if (preg_match('/^librabbitmq version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-librabbitmq', $m['version']);
            }
            if (preg_match('/^AMQP protocol version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-protocol', str_replace('-', '.', $m['version']));
            }
            break;

        case 'bz2':
            if (preg_match('/^BZip2 Version => (?<version>.*),/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name, $m['version']);
            }
            break;

        case 'curl':
            $curl = curl_version();
            ppkg_add($lib, $name, $curl['version'] ?? null);
            $info = ppkg_info($name);
            if (preg_match('{^SSL Version => (?<library>[^\r\n/]+)/(?<version>[^\r\n]+?)\r?$}im', $info, $m)) {
                $library = strtolower($m['library']);
                if ($library === 'openssl') {
                    $parsed = ppkg_parse_openssl($m['version'], $isFips);
                    ppkg_add($lib, $name . '-openssl' . ($isFips ? '-fips' : ''), $parsed, $isFips ? ['curl-openssl'] : []);
                } else {
                    if (str_starts_with($library, '(securetransport)')
                        && preg_match('{^\(securetransport\) ([a-z0-9]+)}', $library, $st)) {
                        $shortlib = 'securetransport';
                        $sslLib = 'curl-' . $st[1];
                    } else {
                        $shortlib = $library;
                        $sslLib = 'curl-openssl';
                    }
                    ppkg_add($lib, $name . '-' . $shortlib, $m['version'], [$sslLib]);
                }
            }
            if (preg_match('{^libSSH Version => (?<library>[^\r\n/]+)/(?<version>.+?)(?:/.*)?$}im', $info, $m)) {
                ppkg_add($lib, $name . '-' . strtolower($m['library']), $m['version']);
            }
            if (preg_match('{^ZLib Version => (?<version>.+)$}im', $info, $m)) {
                ppkg_add($lib, $name . '-zlib', $m['version']);
            }
            break;

        case 'date':
            $info = ppkg_info($name);
            if (preg_match('/^timelib version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-timelib', $m['version']);
            }
            if (preg_match('/^Timezone Database => (?<source>internal|external)$/im', $info, $src)) {
                $external = $src['source'] === 'external';
                if (preg_match('/^"Olson" Timezone Database Version => (?<version>.+?)(?:\.system)?$/im', $info, $m)) {
                    if ($external && in_array('timezonedb', $loaded, true)) {
                        ppkg_add($lib, 'timezonedb-zoneinfo', $m['version'], [$name . '-zoneinfo']);
                    } else {
                        ppkg_add($lib, $name . '-zoneinfo', $m['version']);
                    }
                }
            }
            break;

        case 'fileinfo':
            if (preg_match('/^libmagic => (?<version>.+)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-libmagic', $m['version']);
            }
            break;

        case 'gd':
            ppkg_add($lib, $name, defined('GD_VERSION') ? GD_VERSION : null);
            $info = ppkg_info($name);
            if (preg_match('/^libJPEG Version => (?<version>.+?)(?: compatible)?$/im', $info, $m)) {
                ppkg_add($lib, $name . '-libjpeg', ppkg_parse_libjpeg($m['version']));
            }
            if (preg_match('/^libPNG Version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-libpng', $m['version']);
            }
            if (preg_match('/^FreeType Version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-freetype', $m['version']);
            }
            if (preg_match('/^libXpm Version => (?<versionId>\d+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-libxpm', ppkg_version_id((int) $m['versionId'], 100));
            }
            break;

        case 'gmp':
            ppkg_add($lib, $name, defined('GMP_VERSION') ? GMP_VERSION : null);
            break;

        case 'iconv':
            ppkg_add($lib, $name, defined('ICONV_VERSION') ? (string) ICONV_VERSION : null);
            break;

        case 'intl':
            $info = ppkg_info($name);
            if (defined('INTL_ICU_VERSION')) {
                ppkg_add($lib, 'icu', INTL_ICU_VERSION);
            } elseif (preg_match('/^ICU version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, 'icu', $m['version']);
            }
            if (preg_match('/^ICU TZData version => (?<version>.*)$/im', $info, $m)) {
                ppkg_add($lib, 'icu-zoneinfo', ppkg_parse_zoneinfo($m['version']));
            }
            if (class_exists('ResourceBundle', false)) {
                $bundle = @ResourceBundle::create('root', 'ICUDATA', false);
                if ($bundle !== null) {
                    ppkg_add($lib, 'icu-cldr', $bundle->get('Version'));
                }
            }
            if (class_exists('IntlChar', false)) {
                ppkg_add($lib, 'icu-unicode', implode('.', array_slice(IntlChar::getUnicodeVersion(), 0, 3)));
            }
            break;

        case 'imagick':
            $v = @(new Imagick())->getVersion();
            if (is_array($v) && preg_match('/^ImageMagick (?<version>[\d.]+)(?:-(?<patch>\d+))?/', $v['versionString'] ?? '', $m)) {
                $version = $m['version'];
                if (isset($m['patch'])) {
                    $version .= '.' . $m['patch'];
                }
                ppkg_add($lib, $name . '-imagemagick', $version, ['imagick']);
            }
            break;

        case 'ldap':
            $info = ppkg_info($name);
            if (preg_match('/^Vendor Version => (?<versionId>\d+)$/im', $info, $m)
                && preg_match('/^Vendor Name => (?<vendor>.+)$/im', $info, $vendor)) {
                ppkg_add($lib, $name . '-' . strtolower($vendor['vendor']), ppkg_version_id((int) $m['versionId'], 100));
            }
            break;

        case 'libxml':
            $provides = array_map(
                static fn (string $e): string => $e . '-libxml',
                array_intersect($loaded, ['dom', 'simplexml', 'xml', 'xmlreader', 'xmlwriter'])
            );
            ppkg_add($lib, $name, defined('LIBXML_DOTTED_VERSION') ? LIBXML_DOTTED_VERSION : null, array_values($provides));
            break;

        case 'mbstring':
            $info = ppkg_info($name);
            if (preg_match('/^libmbfl version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-libmbfl', $m['version']);
            }
            if (PHP_VERSION_ID < 90000 && defined('MB_ONIGURUMA_VERSION')) {
                ppkg_add($lib, $name . '-oniguruma', MB_ONIGURUMA_VERSION);
            } elseif (preg_match('/^(?:oniguruma|Multibyte regex \(oniguruma\)) version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-oniguruma', $m['version']);
            }
            break;

        case 'memcached':
            if (preg_match('/^libmemcached version => (?<version>.+)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-libmemcached', $m['version']);
            }
            break;

        case 'openssl':
            if (defined('OPENSSL_VERSION_TEXT')
                && preg_match('{^(?:OpenSSL|LibreSSL)?\s*(?<version>\S+)}i', OPENSSL_VERSION_TEXT, $m)) {
                $parsed = ppkg_parse_openssl($m['version'], $isFips);
                ppkg_add($lib, $name . ($isFips ? '-fips' : ''), $parsed, $isFips ? [$name] : []);
            }
            break;

        case 'pcre':
            if (defined('PCRE_VERSION')) {
                ppkg_add($lib, $name, preg_replace('{^(\S+).*}', '$1', PCRE_VERSION));
            }
            if (preg_match('/^PCRE Unicode Version => (?<version>.+)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-unicode', $m['version']);
            }
            break;

        case 'mysqlnd':
        case 'pdo_mysql':
            if (preg_match('/^(?:Client API version|Version) => mysqlnd (?<version>.+?) /mi', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-mysqlnd', $m['version']);
            }
            break;

        case 'mongodb':
            $info = ppkg_info($name);
            if (preg_match('/^libmongoc bundled version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-libmongoc', $m['version']);
            }
            if (preg_match('/^libbson bundled version => (?<version>.+)$/im', $info, $m)) {
                ppkg_add($lib, $name . '-libbson', $m['version']);
            }
            break;

        case 'pgsql':
            if (defined('PGSQL_LIBPQ_VERSION')) {
                ppkg_add($lib, 'pgsql-libpq', PGSQL_LIBPQ_VERSION);
                break;
            }
            // Composer falls THROUGH to pdo_pgsql here when the constant is
            // absent, and so does this.
        case 'pdo_pgsql':
            if (preg_match('/^PostgreSQL\(libpq\) Version => (?<version>.*)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-libpq', $m['version']);
            }
            break;

        case 'pq':
            if (preg_match('/^libpq => (?<compiled>.+) => (?<linked>.+)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-libpq', $m['linked']);
            }
            break;

        case 'rdkafka':
            if (defined('RD_KAFKA_VERSION')) {
                $id = RD_KAFKA_VERSION;
                ppkg_add($lib, $name . '-librdkafka', sprintf(
                    '%d.%d.%d',
                    ($id & 0x7F000000) >> 24,
                    ($id & 0x00FF0000) >> 16,
                    ($id & 0x0000FF00) >> 8
                ));
            }
            break;

        case 'libsodium':
        case 'sodium':
            if (defined('SODIUM_LIBRARY_VERSION')) {
                ppkg_add($lib, 'libsodium', SODIUM_LIBRARY_VERSION);
            }
            break;

        case 'sqlite3':
        case 'pdo_sqlite':
            if (preg_match('/^SQLite Library => (?<version>.+)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-sqlite', $m['version']);
            }
            break;

        case 'ssh2':
            if (preg_match('/^libssh2 version => (?<version>.+)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name . '-libssh2', $m['version']);
            }
            break;

        case 'xsl':
            ppkg_add($lib, 'libxslt', defined('LIBXSLT_DOTTED_VERSION') ? LIBXSLT_DOTTED_VERSION : null, ['xsl']);
            if (preg_match('/^libxslt compiled against libxml Version => (?<version>.+)$/im', ppkg_info('xsl'), $m)) {
                ppkg_add($lib, 'libxslt-libxml', $m['version']);
            }
            break;

        case 'yaml':
            if (preg_match('/^LibYAML Version => (?<version>.+)$/im', ppkg_info('yaml'), $m)) {
                ppkg_add($lib, $name . '-libyaml', $m['version']);
            }
            break;

        case 'zip':
            if (class_exists('ZipArchive', false) && defined('ZipArchive::LIBZIP_VERSION')) {
                ppkg_add($lib, $name . '-libzip', ZipArchive::LIBZIP_VERSION, ['zip']);
            }
            break;

        case 'zlib':
            if (defined('ZLIB_VERSION')) {
                ppkg_add($lib, $name, ZLIB_VERSION);
            } elseif (preg_match('/^Linked Version => (?<version>.+)$/im', ppkg_info($name), $m)) {
                ppkg_add($lib, $name, $m['version']);
            }
            break;

        default:
            break;
    }
}

echo json_encode([
    'php' => PHP_VERSION,
    'int_size' => PHP_INT_SIZE,
    'debug' => (bool) PHP_DEBUG,
    'zts' => defined('PHP_ZTS') && PHP_ZTS,
    'ipv6' => defined('AF_INET6') || @inet_pton('::') !== false,
    'ext' => (object) $ext,
    'lib' => (object) $lib,
    // Names a library ANSWERS TO without being one — Composer models these as
    // provide links, and `show --platform` does not list them.
    'libprov' => (object) $libprov,
]);

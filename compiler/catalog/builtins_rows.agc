## Every builtin, one file per module (builtins_<module>.agc). A builtin of a family (FAMILIES) is named
## Family.Member.fn, such as OpenSSL.Cipher.aes_256_gcm_encrypt.

import Model from "builtin_model"
import {ROWS as ADDRESS_ROWS} from "builtins_address"
import {ROWS as ATS_ROWS} from "builtins_ats"
import {ROWS as BASE64_ROWS} from "builtins_base64"
import {ROWS as BYTES_ROWS} from "builtins_bytes"
import {ROWS as CHANNEL_ROWS} from "builtins_channel"
import {ROWS as CODEC_ROWS} from "builtins_codec"
import {ROWS as CORE_ROWS} from "builtins_core"
import {ROWS as DIR_ROWS} from "builtins_dir"
import {ROWS as DNS_ROWS} from "builtins_dns"
import {ROWS as ERROR_ROWS} from "builtins_error"
import {ROWS as FILE_ROWS} from "builtins_file"
import {ROWS as FLOAT_ROWS} from "builtins_float"
import {ROWS as FRONTEND_ROWS} from "builtins_frontend"
import {ROWS as HTTPWIRE_ROWS} from "builtins_httpwire"
import {ROWS as INT_ROWS} from "builtins_int"
import {ROWS as IO_ROWS} from "builtins_io"
import {ROWS as JSON_ROWS} from "builtins_json"
import {ROWS as LAZY_ROWS} from "builtins_lazy"
import {ROWS as LIST_ROWS} from "builtins_list"
import {ROWS as LOGREGISTRY_ROWS} from "builtins_logregistry"
import {ROWS as MAP_ROWS} from "builtins_map"
import {ROWS as MATH_ROWS} from "builtins_math"
import {ROWS as NATIVE_ROWS} from "builtins_native"
import {ROWS as OPENSSL_ROWS} from "builtins_openssl"
import {ROWS as OPTIONAL_ROWS} from "builtins_optional"
import {ROWS as PATH_ROWS} from "builtins_path"
import {ROWS as PROCESS_ROWS} from "builtins_process"
import {ROWS as RANDOM_ROWS} from "builtins_random"
import {ROWS as RANGE_ROWS} from "builtins_range"
import {ROWS as REGEXENGINE_ROWS} from "builtins_regexengine"
import {ROWS as RESULT_ROWS} from "builtins_result"
import {ROWS as SET_ROWS} from "builtins_set"
import {ROWS as STD_ROWS} from "builtins_std"
import {ROWS as STRING_ROWS} from "builtins_string"
import {ROWS as SYSTEM_ROWS} from "builtins_system"
import {ROWS as TASK_ROWS} from "builtins_task"
import {ROWS as TCP_ROWS} from "builtins_tcp"
import {ROWS as TEST_ROWS} from "builtins_test"
import {ROWS as TIME_ROWS} from "builtins_time"
import {ROWS as TLS_ROWS} from "builtins_tls"
import {ROWS as ZLIB_ROWS} from "builtins_zlib"

BUILTIN_ROWS: List[Model.Builtin] = (
  ADDRESS_ROWS.concat(ATS_ROWS)
    .concat(BASE64_ROWS)
    .concat(BYTES_ROWS)
    .concat(CHANNEL_ROWS)
    .concat(CODEC_ROWS)
    .concat(CORE_ROWS)
    .concat(DIR_ROWS)
    .concat(DNS_ROWS)
    .concat(ERROR_ROWS)
    .concat(FILE_ROWS)
    .concat(FLOAT_ROWS)
    .concat(FRONTEND_ROWS)
    .concat(HTTPWIRE_ROWS)
    .concat(INT_ROWS)
    .concat(IO_ROWS)
    .concat(JSON_ROWS)
    .concat(LAZY_ROWS)
    .concat(LIST_ROWS)
    .concat(LOGREGISTRY_ROWS)
    .concat(MAP_ROWS)
    .concat(MATH_ROWS)
    .concat(NATIVE_ROWS)
    .concat(OPENSSL_ROWS)
    .concat(OPTIONAL_ROWS)
    .concat(PATH_ROWS)
    .concat(PROCESS_ROWS)
    .concat(RANDOM_ROWS)
    .concat(RANGE_ROWS)
    .concat(REGEXENGINE_ROWS)
    .concat(RESULT_ROWS)
    .concat(SET_ROWS)
    .concat(STD_ROWS)
    .concat(STRING_ROWS)
    .concat(SYSTEM_ROWS)
    .concat(TASK_ROWS)
    .concat(TCP_ROWS)
    .concat(TEST_ROWS)
    .concat(TIME_ROWS)
    .concat(TLS_ROWS)
    .concat(ZLIB_ROWS)
)

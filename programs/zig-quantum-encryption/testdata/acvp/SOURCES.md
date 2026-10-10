# Provenance of testdata/acvp/*.txt

ACVP-Server commit 975de31eb83d87039ec88934fdc47d8c312b892d (2026-08-12), fetched 2026-10-10 from
https://raw.githubusercontent.com/usnistgov/ACVP-Server/master/gen-val/json-files/<Algorithm>/internalProjection.json

SHA-256 of each downloaded file:

```
e67ee6540d40e11506c3c4e3b1f79fc1cefcd49820db99fc61f87cc8ba463baf  ML-DSA-keyGen-FIPS204/internalProjection.json
72dcaf5f69853ca267ccd16af9cb40949786aca0fcfbf05d1ebeba132b93af22  ML-DSA-sigGen-FIPS204/internalProjection.json
47cdd6314c7f746d02421ffcba89d4dbc7bb875ac49e07a029fdfc26fba55437  ML-DSA-sigVer-FIPS204/internalProjection.json
a556952ce869bb89c3a3196a701dad89647c193a34c86eafb61a9d710d5b810f  ML-KEM-encapDecap-FIPS203/internalProjection.json
d7a62a2c3476957f56dd8d24f9004ea6776ccfe995ffe71a65bb9506dc9c7b1b  ML-KEM-keyGen-FIPS203/internalProjection.json
```

Regenerate: python3 -I tools/extract_acvp.py <dir holding the five Algorithm dirs> testdata/acvp 975de31eb83d87039ec88934fdc47d8c312b892d

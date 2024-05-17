---@meta types.lua

---@class Set

---@class pkey
---@field export fun(self: pkey): table
---@field sign fun(self: pkey, msg: string): string
---@field decrypt fun(self: pkey, msg: string, format: "oeap" | nil): string
---@field derive fun(self: pkey, public: pkey): string
---@field to_private_pem fun(self: pkey, cipher: string | nil, password: string | nil): string
---@field to_public_pem fun(self: pkey): string
---@field set_param fun(self: pkey, key: string, val: any)

---@class digest

---@class x509
---@field set_version fun(self: x509, version: integer)
---@field set_pubkey fun(self: x509, pubkey: pkey)
---@field get_pubkey fun(self: x509): pkey
---@field sign fun(self: x509)
---@field fingerprint fun(self: x509, digest: digest): string
---@field export fun(self: x509): string
---@field set_serialNumber fun(self: x509, serial: integer)
---@field set_notBefore fun(self: x509, notBefore: string)
---@field set_notAfter fun(self: x509, notAfter: string)
---@field set_issuerName fun(self: x509, issuerName: table)
---@field set_subjectName fun(self: x509, subjectName: table)
---@field get_subjectName fun(self: x509): table
---@field add_caConstraint fun(self: x509)
---@field add_clientUsageConstraint fun(self: x509)
---@field add_serverUsageConstraint fun(self: x509)
---@field add_subjectKeyIdentifier fun(self: x509, identifier: string)
---@field add_authorityKeyIdentifier fun(self: x509, identifier: string)

---@class bignum
---@field div_mod fun(self: bignum, divisor: bignum): bignum, bignum
---@field mod_exp fun(self: bignum, power: bignum, modulus: bignum): bignum
---@operator add(bignum): bignum
---@operator sub(bignum): bignum
---@operator mul(bignum): bignum
---@operator idiv(bignum): bignum
---@operator mod(bignum): bignum
---@operator pow(bignum): bignum
---@operator shl(integer): bignum
---@operator shr(integer): bignum
---@operator lt(bignum): bool
---@operator gt(bignum): bool
---@operator le(bignum): bool
---@operator tostring: string
---@operator unm: bignum

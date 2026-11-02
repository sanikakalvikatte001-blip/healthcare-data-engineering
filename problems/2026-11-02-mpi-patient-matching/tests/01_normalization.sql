-- pgTAP: normalization functions
BEGIN;
SELECT plan(24);

-- names
SELECT is(util.norm_name('  o''Brien Jr. '), 'OBRIEN',  'apostrophe and Jr. suffix removed');
SELECT is(util.norm_name('Mary-Ann'),        'MARYANN', 'hyphen removed');
SELECT is(util.norm_name('Smith, III'),      'SMITH',   'roman numeral suffix removed');
SELECT is(util.norm_name('   '),             NULL,      'blank name is NULL');
SELECT is(util.canon_first('bob'),           'ROBERT',  'nickname resolved');
SELECT is(util.canon_first('Roberta'),       'ROBERTA', 'non-nickname unchanged');

-- dates of birth in each source format
SELECT is(util.parse_dob('1984-07-09'),  date '1984-07-09', 'ISO (EHR)');
SELECT is(util.parse_dob('07/09/1984'),  date '1984-07-09', 'MM/DD/YYYY (lab)');
SELECT is(util.parse_dob('19840709'),    date '1984-07-09', 'YYYYMMDD (X12)');
SELECT is(util.parse_dob('1985-02-30'),  NULL::date,        'impossible date rejected');
SELECT is(util.parse_dob('2999-01-01'),  NULL::date,        'future date rejected');
SELECT is(util.parse_dob('unknown'),     NULL::date,        'free text rejected');

-- SSN placeholders carry no identity
SELECT is(util.norm_ssn('912-34-5678')::text, '912345678',  'formatted SSN normalized');
SELECT is(util.norm_ssn('999-99-9999')::text, NULL,         'all-nines placeholder rejected');
SELECT is(util.norm_ssn('123456789')::text,   NULL,         '123456789 placeholder rejected');
SELECT is(util.norm_ssn('666-12-3456')::text, NULL,         'never-issued area 666 rejected');
SELECT is(util.norm_ssn('912-00-3456')::text, NULL,         'group 00 rejected');

-- phone, sex, zip, address
SELECT is(util.norm_phone('1 (212) 555-0143')::text, '2125550143', 'country code dropped');
SELECT is(util.norm_phone('(000) 000-0000')::text,   NULL,         'all-zero phone rejected');
SELECT is(util.norm_sex('Female')::text, 'F', 'spelled-out sex');
SELECT is(util.norm_sex('1')::text,      'M', 'X12 numeric sex');
SELECT is(util.norm_zip('12345-0001')::text, '12345', 'ZIP+4 truncated');
SELECT is(util.norm_address('742 Maple Street, Apt. 4'), '742 MAPLE ST APT 4', 'street abbreviated');
SELECT is(util.norm_address('742 MAPLE AVE.'), '742 MAPLE AVE', 'punctuation removed');

SELECT * FROM finish();
ROLLBACK;

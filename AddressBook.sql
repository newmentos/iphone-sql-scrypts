SELECT ifnull(ABPerson.first, '') || ' ' || ifnull(ABPerson.last, ''),
       ABMultiValue.value
  FROM ABPerson,
       ABMultiValue
 WHERE ABMultiValue.record_id = ABPerson.ROWID;



-- https://linuxsleuthing.blogspot.com/2012/10/whos-texting-ios6-smsdb.html

SELECT 
  m.rowid as RowID, 
  DATETIME(date + 978307200, 'unixepoch', 'localtime') as Date, 
  h.id as "Phone Number", m.service as Service, 
  CASE is_from_me 
    WHEN 0 THEN "Received" 
    WHEN 1 THEN "Sent" 
    ELSE "Unknown" 
  END as Type, 
  CASE 
    WHEN date_read > 0 then DATETIME(date_read + 978307200, 'unixepoch')
    WHEN date_delivered > 0 THEN DATETIME(date_delivered + 978307200, 'unixepoch') 
    ELSE NULL END as "Date Read/Sent", 
  text as Text 
FROM message m, handle h 
WHERE h.rowid = m.handle_id 
ORDER BY m.rowid ASC;
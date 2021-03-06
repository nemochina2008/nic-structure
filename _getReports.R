library(httr)
library(data.table)
library(stringr)
library(rvest)
cc = fread('app/entityTypeGrouping.csv')

params = list(
  rbRptFormatPDF = 'rbRptFormatPDF',
  lbTypeOfInstitution = '-99',
  grpInstitution = 'rbCurInst',
  grpHMDA = 'rbNonHMDA',
  btnSubmit = 'Submit'
)

pdfName = function(rssd, as_of_date) {
  paste0('pdf/', rssd, '-', gsub('-', '', as_of_date), '.pdf')
}

pdf2txt = function(file_name) {
  # Install xpdf from http://www.foolabs.com/xpdf/download.html
  # and add to system PATH
  system2(
    command = 'pdftotext',
    args = c('-raw', '-nopgbrk', file_name, '-'),
    stdout = TRUE
  )

}

txt2clean = function(f, save_name) {
  txt = data.table(V1 = f)
  
  # Drop this pattern: <br>------ Repeat at ####
  # Sometimes splits into multiple lines
  drop = txt[, which(grepl('<br>', V1) & !grepl('at \\d+', V1)) + 1]
  if (length(drop) > 0) txt = txt[-drop]
  
  # Careful -- txt[-v] drops all rows when v is empty
  paste.idx = txt[, which(grepl('<br>', V1) & !grepl('^\\d+ -+\\*', V1))]
  txt[paste.idx-1, V1:= paste(V1, txt[paste.idx, V1])]
  if (length(paste.idx) > 0) { txt = txt[-paste.idx] }
  
  # Need to handle both of the following (how to use just one regex?):
  # "1915 -----* + ^ ARAMARK (3837841)<br>----- Repeat at 12171 1914 NEW YORK NY Domestic Entity Other"
  # "1915 -----* + ^ ARAMARK (3837841)<br>----- Repeat at"
  txt[, V1:= gsub(' ?<br>.*(?= \\d+ )', '', V1, perl=T)]
  txt[, V1:= gsub(' ?<br>.*', '', V1)]
  
  # RowNum > 9999 split on two lines; paste
  # Most of the time, other info is on third line; but sometimes on second, so
  # do this in two steps
  paste.idx = txt[, which(grepl('^\\d+{4}$', V1))]
  txt[paste.idx, V1:= paste0(V1, txt[paste.idx+1, V1])]
  if (length(paste.idx) > 0) { txt = txt[-(paste.idx + 1)] }
  
  paste.idx = txt[, which(grepl('^\\d+{5}$', V1))]
  txt[paste.idx, V1:= paste(V1, txt[paste.idx+1, V1])]
  if (length(paste.idx) > 0) { txt = txt[-(paste.idx + 1)] }
  
  # Remove header/footer - vectorization "trick"
  txt[, V2:= cumsum( c(1, grepl('^\\d+ -+(\\*|[^ ])', V1[-1])) )]
  txt[, V3:= ifelse(grepl('^Report created', V1), V2, 0)]
  txt[, drop:= V2 - cummax(V3) == 0]
  
  txt = txt[1:(grep('^Total Records', V1)-1)][
    !as.logical(drop), .(V1,V2)][
      , paste(V1, collapse=' '), by='V2'][
        !duplicated(V1)][
          !grepl('Repeat', V1)]
  
  # manual fix (affects Goldman, Citigroup)
  txt[, V1:= sub('(SALVADOR)(Foreign|International|Finance)', '\\1 \\2', V1)]
  
  # Insert "~" delimiters, split
  txt[, V1:= V1 %>% str_replace('(\\d+) ', '\\1~') %>%
        str_replace('(~-*\\*?) ?', '\\1~') %>%
        str_replace('(.*)(~\\+?) ?', '\\1\\2~') %>%
        str_replace('(.*) \\((\\d{3,})\\) ?', '\\1~\\2~') %>%
        str_replace('(~\\d{3,}~\\d*) ?', '\\1~') %>%
        str_replace(' ([A-Z][a-z]+)', '~\\1')]
  
  dt = txt[, tstrsplit(V1, '~', type.convert=T)]
  
  setnames(dt, c('Idx','Level','Note','Name','Id_Rssd','Parent','Loc','Type'))
  
  dt[, Name:= gsub('^[ ^]+', '', Name)]
  dt[, Loc:= gsub(' *\\(OTHER\\)', '', Loc)]
  dt[, Tier:= str_count(Level, '-') + 1]
  dt[Note=='', Note:= NA_character_]
  dt[, Type:= cc$Type.code[match(Type, cc$domain)]]
  setnames(dt, 'Type', 'Type.code')
  
  stopifnot( all(dt$Parent < dt$Idx, na.rm=T) )
  
  dt[, Level:= NULL]
  
  dt = dt[!duplicated(Idx)]
  # An rssd has an entry for each of its parents; results
  # in having multiple Idx; each of its children has an entry
  # for each Idx, so there are duplicate links. Remove these.
  dt[, Parent:= Id_Rssd[match(Parent,Idx)]]
  dt[, Tier:= min(Tier), by=.(Id_Rssd, Parent)]
  dt = dt[!duplicated(dt[, .(Id_Rssd, Parent)])]
  
  fwrite(dt, save_name, quote=T)
  
}


getReport = function(rssd, dt_end=99991231, as_of_date, redownload=FALSE) {
  # as_of_date: yyyy-mm-dd
  file_name = pdfName(rssd, as_of_date)
  
  if (!file.exists(file_name) | redownload) {
    url = paste0(
      'https://www.ffiec.gov/nicpubweb/nicweb/OrgHierarchySearchForm.aspx',
      '?parID_RSSD=', rssd, '&parDT_END=', dt_end )
    
    html = GET(url)
    
    viewstate = sub('.*id="__VIEWSTATE" value="([0-9a-zA-Z+/=]*).*', '\\1', html)
    event = sub('.*id="__EVENTVALIDATION" value="([0-9a-zA-Z+/=]*).*', '\\1', html)
    params[['__VIEWSTATE']] = viewstate
    params[['__EVENTVALIDATION']] = event
    params[['txtAsOfDate']] = format.Date(as_of_date, '%m/%d/%Y')
    
    POST(url, body=params, write_disk(file_name, overwrite=T))
    
    txt2clean( pdf2txt(file_name), save_name=gsub('pdf','txt', file_name) )
  }
  
}

# http://r.789695.n4.nabble.com/writing-binary-data-from-RCurl-and-postForm-td4710802.html
# http://stackoverflow.com/questions/41357811/passing-correct-params-to-rcurl-postform


getInstHistory = function(rssd, dt_end=99991231) {
  url = paste0(
    'https://www.ffiec.gov/nicpubweb/nicweb/InstitutionHistory.aspx',
    '?parID_RSSD=', rssd, '&parDT_END=', dt_end )
  
  table = read_html(url) %>%
    html_nodes(xpath='//table[@class="datagrid"]') %>%
    .[[1]] %>%
    html_table(header=TRUE)
  
  table$Id_Rssd = rssd
  table
}


getInstPrimaryActivity = function(rssd, dt_end=99991231) {
  url = paste0(
    'https://www.ffiec.gov/nicpubweb/nicweb/InstitutionProfile.aspx',
    '?parID_RSSD=', rssd, '&parDT_END=', dt_end )
  
  table = read_html(url) %>%
    html_nodes(xpath='//table[@id="Table2"]') %>%
    .[[1]] %>%
    html_table(fill=TRUE) %>%
    setDT()
  
  data.table(Id_Rssd=rssd, Activity=table[grepl('Activity:', X1),
                                          gsub('Activity:\\s', '', X1)])
}


getBhcParent = function(rssd, dtend=99991231) {
  url = paste0(
    'https://www.ffiec.gov/nicpubweb/nicweb/OrgHierarchySearchForm.aspx',
    '?parID_RSSD=', rssd, '&parDT_END=', dt_end )
  
  nodes = read_html(url) %>%
    html_nodes(xpath='//select[@id="lbTopHolders"]/option')
  
  if (length(nodes) > 0) {
    parents = sapply(nodes, html_attr, 'value')
  }
}


getBhcInstHistories = function() {
  bhcNameList = fread('hc-name-list.txt', key='ID_RSSD')
  bhcHistories_file = 'bhc-institution-histories.txt'
  bhcHistories_done = if (file.exists(bhcHistories_file)) {
    fread(bhcHistories_file) } else NULL
  
  # Include large IHCs -- Credit Suisse USA, UBS Americas, BNP Paribas
  hc10bnRssds = fread('app/data/HC10bn.csv')$`RSSD ID`
  rssdList = union(bhcNameList$ID_RSSD, hc10bnRssds)
  rssdList = setdiff(rssdList, bhcHistories_done$Id_Rssd)
  
  bhcHistories = list()
  
  i = 0
  for (rssd in rssdList) {
    i = i + 1
    if (i%%50 == 0) {
      cat(i, ' of ', length(rssdList), '\n') }
    j = as.character(rssd)
    
    # Will miss those that became inactive since hc-name-list updated
    tryCatch({
      dt_end = bhcNameList[J(rssd), NAME_END_DATE[.N]]
      bhcHistories[[j]] = getInstHistory(
        rssd, dt_end = if (!is.na(dt_end)) dt_end else 99991231) },
      error = function(e) message(e) )
  }
  
  bhcHistories = rbindlist(bhcHistories)
  setcolorder(bhcHistories, c('Id_Rssd','Event Date','Historical Event'))
  
  bhcHistories_done = rbind(bhcHistories_done, bhcHistories)
  
  setkey(bhcHistories_done, Id_Rssd, `Event Date`)
  fwrite(bhcHistories_done, bhcHistories_file, quote=T)
  
}


getRssdPrimaryActivities = function(rssdsList) {
  rssdActivities = list()
  
  i = 0
  for (rssd in rssdsList) {
    i = i + 1
    if (i%%100 == 0) {
      cat(i, ' of ', length(rssdsList), '\n') }
    j = as.character(rssd)
    
    tryCatch({
      rssdActivities[[j]] = getInstPrimaryActivity(rssd)},
      error = function(e) NULL,
      warning = function(w) NULL)
  }
  
  rssdActivities = rbindlist(rssdActivities)
  
  fwrite(rssdActivities, 'rssd-primary-activities.txt', quote=T)
  
}


updateBhcList = function() {
  # Use most recent file for each rssd (need to get most recent HC name)
  bhcList = dir('txt/', '.txt', full.names=T) %>%
    `[`(!duplicated(str_extract(., '\\d+'), fromLast=TRUE)) %>%
    lapply(fread, nrows=1, select=c('Name','Id_Rssd')) %>%
    rbindlist() %>%
    setkey(Name)
  
  bhcList = setNames(bhcList$Id_Rssd, bhcList$Name)
  
  save(bhcList, file = 'app/bhcList.RData')
  
  ### Also update the histories saved file (saving a subset to
  # save space)
  histories = fread('bhc-institution-histories.txt', key='Id_Rssd')
  histories = histories[J(bhcList)]
  
  save(histories, file='app/data/histories.RData')
}



updateAll = function(rssds=NULL, start_date='2000-01-01', redownload=FALSE) {
  # Master function to update the data
  load('app/bhcList.RData')
  bhcList = c(bhcList, rssds)
  
  # Load/process 'histories' & function getBhcSpan()
  source('_getBhcSpan.R', local=TRUE)
  
  as_of_dates = lapply(bhcList, getBhcSpan, start_date)
  
  oldFiles = setdiff(
    dir('txt/', full.names=TRUE),
    if (redownload) gsub('pdf', 'txt',
                         unlist(Map(pdfName, bhcList, as_of_dates)))
  )
  
  # Download new pdfs and convert to txt
  for (j in seq_along(bhcList)) {
    if (length(as_of_dates[[j]]) > 0) {
      cat('Requesting', names(bhcList)[j], '...\n')
      
      mapply(getReport, rssd = bhcList[j], as_of_date = as_of_dates[[j]],
             redownload = redownload)
    }
  }
  
  cat('\n\nUpdating app/BhcList.Rdata...\n')
  updateBhcList()
  
  newFiles = setdiff(dir('txt/', full.names=TRUE), oldFiles)
  
  # Run the geolocator
  system2('python', args=c('_geolocator.py', '--files', newFiles), invis=F)
  
  # Prompt to continue (may need to update _locationMasterEdits first)
  menu(c('Yes','No'), title='Continue?')
  
  system2('python', args=c('_locationMasterEdits.py'))
  
  # Run the geolocator again (in case updates were made)
  system2('python', args=c('_geolocator.py', '--files', newFiles), invis=F)
  
  cat('Converting txt/ to app/rdata/...\n')
  source('_txt2rdata.R', local=TRUE)
  
  cat('Tabulating entities...\n')
  source('_tabulateEntities.R', local=TRUE)
  
  cat('Tabulating assets...\n')
  source('_tabulateAssets.R', local=TRUE)
  
  cat('Updating coverage plot...\n')
  source('_plotCoverage.R', local=TRUE)
  
}



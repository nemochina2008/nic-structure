library(data.table)
library(stringr)

regions = fread('app/Country-regions_OFC.csv')
states.rx = paste0('(',paste(state.abb, collapse='|'),'|DC)$')
cc = fread('app/entityTypeGrouping.csv')
hc.types = cc[group=='Holding Company', Type.code]

files = dir('txt/', full.names=T)

# By world region
cat('Tabulating world regions...\n')
dt = rbindlist( lapply( files, function(z) {
  rssd = as.numeric(str_extract(z, '\\d+'))
  dat = fread(z, select=c('Id_Rssd','Type.code','label'))
  
  if (dat[, !Type.code[1] %in% hc.types] | !nrow(dat) > 1) return(NULL)
  
  # Unique entities
  dat = dat[!duplicated(Id_Rssd)]
  
  dat[, Country:= gsub('.*(?<=,) *(.*)', '\\1', label, perl=T)]
  dat[grepl(states.rx, label), Country:= 'USA']
  
  # Remove nomatch=0 to check for missed values
  dat = regions[dat[, .(Id_Rssd=rssd, Country)], on='Country', nomatch=0]
  
  dat = dat[, .N, by=.(Id_Rssd, Region)]
  dat[, asOfDate:= as.Date( str_extract(z, '(?<=-)\\d+'), '%Y%m%d')]
} ) )

fwrite(dt, 'app/data/EntitiesByRegion.csv')


# By OFC status (IMF Classification)
cat('Tabulating Offshore status...\n')
dt = rbindlist( lapply( files, function(z) {
  rssd = as.numeric(str_extract(z, '\\d+'))
  dat = fread(z, select=c('Id_Rssd','Type.code','label'))
  
  if (dat[, !Type.code[1] %in% hc.types] | !nrow(dat) > 1) return(NULL)
  
  # Unique entities
  dat = dat[!duplicated(Id_Rssd)]
  
  dat[, Country:= gsub('.*(?<=,) *(.*)', '\\1', label, perl=T)]
  dat[grepl(states.rx, label), Country:= 'USA']
  dat[grepl('Macao|Macau|Labuan', label), Country:=
        str_extract(label, 'Macao|Macau|Labuan')]
  
  # Remove nomatch=0 to check for missed values
  dat = regions[dat[, .(Id_Rssd=rssd, Country)], on='Country', nomatch=0]
  
  dat = dat[, .(N = sum(IMF_OFC==1)), by='Id_Rssd']
  dat[, asOfDate:= as.Date( str_extract(z, '(?<=-)\\d+'), '%Y%m%d')]
} ) )

fwrite(dt, 'app/data/EntitiesByOFC.csv')


# By entity type
cat('Tabulating entity types...\n')
dt = rbindlist( lapply( files, function(z) {
  rssd = as.numeric(str_extract(z, '\\d+'))
  dat = fread(z, select=c('Id_Rssd','Type.code'))
  
  if (dat[, !Type.code[1] %in% hc.types] | !nrow(dat) > 1) return(NULL)
  
  # Unique entities
  dat = dat[!duplicated(Id_Rssd)]
  dat[, Id_Rssd:= rssd]
  
  dat = dat[, .N, by=.(Id_Rssd,Type.code)]
  dat[, Type.code:= cc$domain[match(Type.code, cc$Type.code)]]
  dat[, asOfDate:= as.Date( str_extract(z, '(?<=-)\\d+'), '%Y%m%d')]
} ) )

setnames(dt, 'Type.code', 'Type')

fwrite(dt, 'app/data/EntitiesByType.csv')


# Link-node ratio
cat('Tabulating link-node ratios...\n')
dt = rbindlist(lapply( files, function(z) {
  rssd = as.numeric(str_extract(z, '\\d+'))
  dat = fread(z, select=c('Id_Rssd','Type.code'))
  
  if (dat[, !Type.code[1] %in% hc.types] | !nrow(dat) > 1) return(NULL)
  
  dat[, .(Id_Rssd = rssd,
          asOfDate = as.Date( str_extract(z, '(?<=-)\\d+'), '%Y%m%d'),
          link.node.ratio = .N / (uniqueN(Id_Rssd)-1))]
})); rm(files)

fwrite(dt, 'app/data/linkNodeRatio.csv')



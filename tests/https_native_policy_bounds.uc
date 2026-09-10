const policy=loadfile(ARGV[0]+'/policy.uc')()();
function repeat(count,char) {let value='';for(let i=0;i<count;i++)value+=char;return value;}
function check(method,value,valid) {let accepted=true;try{policy[method](value);}catch(_){accepted=false;}if(accepted!=valid)die(sprintf('policy_boundary_changed: %s %J',method,value));}
for(let count in [0,1,63,64,65])check('identifier',repeat(count,'a'),count>0&&count<=64);
for(let value in ['-a','_a','a.b','a\n','é',null,3])check('identifier',value,false);
for(let value in ['0','a-b','a_b'])check('identifier',value,true);
for(let count in [0,1,62,63,64])check('hostname',repeat(count,'a')+'.test',count>0&&count<=63);
for(let value in ['a-b.test','A.TEST.','a.test..',repeat(63,'a')+'.'+repeat(63,'b')+'.'+repeat(63,'c')+'.'+repeat(61,'d')])check('hostname',value,true);
for(let value in ['-a.test','a-.test','a..test','a_b.test','a\n.test','é.test','127.0.0.1',repeat(63,'a')+'.'+repeat(63,'b')+'.'+repeat(63,'c')+'.'+repeat(62,'d')])check('hostname',value,false);
print('policy: identifier, DNS label, full hostname, normalization and invalid-input boundaries passed\n');

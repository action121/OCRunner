//
//  ORunner+Execute.m
//  MangoFix
//
//  Created by Jiang on 2020/5/8.
//  Copyright © 2020 yongpengliang. All rights reserved.
//

#import "RunnerClasses+Execute.h"
#import "MFScopeChain.h"
#import "util.h"
#import "MFMethodMapTable.h"
#import "MFPropertyMapTable.h"
#import "MFVarDeclareChain.h"
#import "MFBlock.h"
#import "MFValue.h"
#import "MFStaticVarTable.h"
#import "ORStructDeclare.h"
#import <objc/message.h>
#import "ORTypeVarPair+TypeEncode.h"
#import "ORCoreImp.h"
#import "ORSearchedFunction.h"

#if DEBUG
NSMutableArray *ORDebugMainFrameStack(void){
    NSMutableDictionary *threadInfo = [[NSThread mainThread] threadDictionary];
    return threadInfo[@"ORDebugStack"];
}
NSMutableArray *ORDebugFrameStack(void){
    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    NSMutableArray *stack = threadInfo[@"ORDebugStack"];
    if (!stack) {
        stack = [NSMutableArray array];
        threadInfo[@"ORDebugStack"] = stack;
    }
    return stack;
}
void ORDebugFrameStackPush(MFValue *value, NSObject *node){
    if (value) {
        [ORDebugFrameStack() addObject:@[value, node]];
    }else{
        [ORDebugFrameStack() addObject:@[node]];
    }
}
void ORDebugFrameStackPop(void){
    [ORDebugFrameStack() removeLastObject];
}
NSString *OCRunnerFrameStackHistory(void){
    NSMutableArray *frames = ORDebugMainFrameStack();
    NSMutableString *log = [@"OCRunner Frames:\n\n" mutableCopy];
    for (NSArray *frame in frames) {
        if (frame.count == 2) {
            MFValue *target = frame.firstObject;
            ORMethodImplementation *imp = frame.lastObject;
            [log appendFormat:@"%@ %@ %@\n", imp.declare.isClassMethod ? @"+" : @"-", target.objectValue, imp.declare.selectorName];
        }else{
            ORFunctionImp *imp = frame.firstObject;
            if (imp.declare.funVar.varname == nil){
                [log appendString:@"  Block Call \n"];
            }else{
                [log appendFormat:@"  CFunction: %@\n", imp.declare.funVar.varname];
            }
        }
    }
    return log;
}
#endif

static MFValue * invoke_MFBlockValue(MFValue *blockValue, NSArray *args){
    const char *blockTypeEncoding = [MFBlock typeEncodingForBlock:blockValue.objectValue];
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:blockTypeEncoding];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    [invocation setTarget:blockValue.objectValue];
    NSUInteger numberOfArguments = [sig numberOfArguments];
    if (numberOfArguments - 1 != args.count) {
        //            mf_throw_error(expr.lineNumber, MFRuntimeErrorParameterListCountNoMatch, @"expect count: %zd, pass in cout:%zd",numberOfArguments - 1,expr.args.count);
        return [MFValue valueWithObject:nil];
    }
    //根据MFValue的type传入值的原因: 模拟在OC中的调用
    for (NSUInteger i = 1; i < numberOfArguments; i++) {
        MFValue *argValue = args[i -1];
        // 基础类型转换
        argValue.typeEncode = [sig getArgumentTypeAtIndex:i];
        [invocation setArgument:argValue.pointer atIndex:i];
    }
    [invocation invoke];
    const char *retType = [sig methodReturnType];
    retType = removeTypeEncodingPrefix((char *)retType);
    if (*retType == 'v') {
        return [MFValue voidValue];
    }
    void *retValuePtr = alloca(mf_size_with_encoding(retType));
    [invocation getReturnValue:retValuePtr];
    return [[MFValue alloc] initTypeEncode:retType pointer:retValuePtr];;
}

static void replace_method(Class clazz, ORMethodImplementation *methodImp, MFScopeChain *scope){
    ORMethodDeclare *declare = methodImp.declare;
    NSString *methodName = declare.selectorName;
    SEL sel = NSSelectorFromString(methodName);

    BOOL needFreeTypeEncoding = NO;
    const char *typeEncoding;
    Method ocMethod;
    if (methodImp.declare.isClassMethod) {
        ocMethod = class_getClassMethod(clazz, sel);
    }else{
        ocMethod = class_getInstanceMethod(clazz, sel);
    }
    if (ocMethod) {
        typeEncoding = method_getTypeEncoding(ocMethod);
    }else{
        typeEncoding = methodImp.declare.returnType.typeEncode;
        needFreeTypeEncoding = YES;
        typeEncoding = mf_str_append(typeEncoding, "@:"); //add self and _cmd
        for (ORTypeVarPair *pair in methodImp.declare.parameterTypes) {
            const char *paramTypeEncoding = pair.typeEncode;
            const char *beforeTypeEncoding = typeEncoding;
            typeEncoding = mf_str_append(typeEncoding, paramTypeEncoding);
            free((void *)beforeTypeEncoding);
        }
    }
    Class c2 = methodImp.declare.isClassMethod ? objc_getMetaClass(class_getName(clazz)) : clazz;
    if (class_respondsToSelector(c2, sel)) {
        NSString *orgSelName = [NSString stringWithFormat:@"ORG%@",methodName];
        SEL orgSel = NSSelectorFromString(orgSelName);
        if (!class_respondsToSelector(c2, orgSel)) {
            class_addMethod(c2, orgSel, method_getImplementation(ocMethod), typeEncoding);
        }
    }
    
    MFMethodMapTableItem *item = [[MFMethodMapTableItem alloc] initWithClass:c2 method:methodImp];
    [[MFMethodMapTable shareInstance] addMethodMapTableItem:item];
    
    void *imp = register_method(&methodIMP, declare.parameterTypes, declare.returnType, (__bridge_retained void *)methodImp);
    class_replaceMethod(c2, sel, imp, typeEncoding);
    if (needFreeTypeEncoding) {
        free((void *)typeEncoding);
    }
}

static void replace_getter_method(Class clazz, ORPropertyDeclare *prop){
    SEL getterSEL = NSSelectorFromString(prop.var.var.varname);
    const char *retTypeEncoding  = prop.var.typeEncode;
    const char * typeEncoding = mf_str_append(retTypeEncoding, "@:");
    void *imp = register_method(&getterImp, @[], prop.var, (__bridge  void *)prop);
    class_replaceMethod(clazz, getterSEL, imp, typeEncoding);
    free((void *)typeEncoding);
}

static void replace_setter_method(Class clazz, ORPropertyDeclare *prop){
    NSString *name = prop.var.var.varname;
    NSString *str1 = [[name substringWithRange:NSMakeRange(0, 1)] uppercaseString];
    NSString *str2 = name.length > 1 ? [name substringFromIndex:1] : nil;
    SEL setterSEL = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",str1,str2]);
    const char *prtTypeEncoding  = prop.var.typeEncode;
    const char * typeEncoding = mf_str_append("v@:", prtTypeEncoding);
    void *imp = register_method(&setterImp, @[prop.var], [ORTypeVarPair typePairWithTypeKind:TypeVoid],(__bridge_retained  void *)prop);
    class_replaceMethod(clazz, setterSEL, imp, typeEncoding);
    free((void *)typeEncoding);
}

void copy_undef_var(id exprOrStatement, MFVarDeclareChain *chain, MFScopeChain *fromScope, MFScopeChain *destScope);
void copy_undef_vars(NSArray *exprOrStatements, MFVarDeclareChain *chain, MFScopeChain *fromScope, MFScopeChain *destScope){
    for (id exprOrStatement in exprOrStatements) {
        copy_undef_var(exprOrStatement, chain, fromScope, destScope);
    }
}
/// Block执行时的外部变量捕获
void copy_undef_var(id exprOrStatement, MFVarDeclareChain *chain, MFScopeChain *fromScope, MFScopeChain *destScope){
    if (!exprOrStatement) {
        return;
    }
    Class exprOrStatementClass = [exprOrStatement class];
    if (exprOrStatementClass == [ORValueExpression class]) {
        ORValueExpression *expr = (ORValueExpression *)exprOrStatement;
        switch (expr.value_type) {
            case OCValueDictionary:{
                for (NSArray *kv in expr.value) {
                    ORNode *keyExp = kv.firstObject;
                    ORNode *valueExp = kv.firstObject;
                    copy_undef_var(keyExp, chain, fromScope, destScope);
                    copy_undef_var(valueExp, chain, fromScope, destScope);
                }
                break;
            }
            case OCValueArray:{
                for (ORNode *valueExp in expr.value) {
                    copy_undef_var(valueExp, chain, fromScope, destScope);
                }
                break;
            }
            case OCValueSelf:
            case OCValueSuper:{
                destScope.instance = fromScope.instance;
                break;
            }
            case OCValueVariable:{
                NSString *identifier = expr.value;
                if (![chain isInChain:identifier]) {
                   MFValue *value = [fromScope recursiveGetValueWithIdentifier:identifier];
                    if (value) {
                        [destScope setValue:value withIndentifier:identifier];
                    }
                }
            }
            default:
                break;
        }
    }else if (exprOrStatementClass == ORAssignExpression.class) {
        ORAssignExpression *expr = (ORAssignExpression *)exprOrStatement;
        copy_undef_var(expr.value, chain, fromScope, destScope);
        copy_undef_var(expr.expression, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORBinaryExpression.class){
        ORBinaryExpression *expr = (ORBinaryExpression *)exprOrStatement;
        copy_undef_var(expr.left, chain, fromScope, destScope);
        copy_undef_var(expr.right, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORTernaryExpression.class){
        ORTernaryExpression *expr = (ORTernaryExpression *)exprOrStatement;
        copy_undef_var(expr.expression, chain, fromScope, destScope);
        copy_undef_vars(expr.values, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORUnaryExpression.class){
        ORUnaryExpression *expr = (ORUnaryExpression *)exprOrStatement;
        copy_undef_var(expr.value, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORCFuncCall.class){
        ORCFuncCall *expr = (ORCFuncCall *)exprOrStatement;
        copy_undef_var(expr.caller, chain, fromScope, destScope);
        copy_undef_vars(expr.expressions, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORSubscriptExpression.class){
        ORSubscriptExpression *expr = (ORSubscriptExpression *)exprOrStatement;
        copy_undef_var(expr.caller, chain, fromScope, destScope);
        copy_undef_var(expr.keyExp, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORMethodCall.class){
        ORMethodCall *expr = (ORMethodCall *)exprOrStatement;
        copy_undef_var(expr.caller, chain, fromScope, destScope);
        copy_undef_vars(expr.values, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORFunctionImp.class){
        ORFunctionImp *expr = (ORFunctionImp *)exprOrStatement;
        ORFuncDeclare *funcDeclare = expr.declare;
        MFVarDeclareChain *funcChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        NSArray <ORTypeVarPair *>*params = funcDeclare.funVar.pairs;
        for (ORTypeVarPair *param in params) {
            [funcChain addIndentifer:param.var.varname];
        }
        copy_undef_var(expr.scopeImp, funcChain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORScopeImp.class){
        ORScopeImp *scopeImp = (ORScopeImp *)exprOrStatement;
        MFVarDeclareChain *scopeChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_vars(scopeImp.statements, scopeChain, fromScope, destScope);
        return;
    }
    else if (exprOrStatementClass == ORDeclareExpression.class){
        ORDeclareExpression *expr = (ORDeclareExpression *)exprOrStatement;
        NSString *name = expr.pair.var.varname;
        [chain addIndentifer:name];
        copy_undef_var(expr.expression, chain, fromScope, destScope);
        return;
        
    }else if (exprOrStatementClass == ORIfStatement.class){
        ORIfStatement *ifStatement = (ORIfStatement *)exprOrStatement;
        copy_undef_var(ifStatement.condition, chain, fromScope, destScope);
        MFVarDeclareChain *ifChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(ifStatement.scopeImp, ifChain, fromScope, destScope);
        copy_undef_var(ifStatement.last, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORSwitchStatement.class){
        ORSwitchStatement *swithcStatement = (ORSwitchStatement *)exprOrStatement;
        copy_undef_var(swithcStatement.value, chain, fromScope, destScope);
        copy_undef_vars(swithcStatement.cases, chain, fromScope, destScope);
        MFVarDeclareChain *defChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(swithcStatement.scopeImp, defChain, fromScope, destScope);
        return;
        
    }else if (exprOrStatementClass == ORCaseStatement.class){
        ORCaseStatement *caseStatement = (ORCaseStatement *)exprOrStatement;
        copy_undef_var(caseStatement.value, chain, fromScope, destScope);
        MFVarDeclareChain *caseChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(caseStatement.scopeImp, caseChain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORForStatement.class){
        ORForStatement *forStatement = (ORForStatement *)exprOrStatement;
        MFVarDeclareChain *forChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_vars(forStatement.varExpressions, forChain, fromScope, destScope);
        copy_undef_var(forStatement.condition, forChain, fromScope, destScope);
        copy_undef_vars(forStatement.expressions, forChain, fromScope, destScope);
        copy_undef_var(forStatement.scopeImp, forChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORForInStatement.class){
        ORForInStatement *forEachStatement = (ORForInStatement *)exprOrStatement;
        MFVarDeclareChain *forEachChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(forEachStatement.expression, forEachChain, fromScope, destScope);
        copy_undef_var(forEachStatement.value, forEachChain, fromScope, destScope);
        copy_undef_var(forEachStatement.scopeImp, forEachChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORWhileStatement.class){
        ORWhileStatement *whileStatement = (ORWhileStatement *)exprOrStatement;
        copy_undef_var(whileStatement.condition, chain, fromScope, destScope);
        MFVarDeclareChain *whileChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(whileStatement.scopeImp, whileChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORDoWhileStatement.class){
        ORDoWhileStatement *doWhileStatement = (ORDoWhileStatement *)exprOrStatement;
        copy_undef_var(doWhileStatement.condition, chain, fromScope, destScope);
        MFVarDeclareChain *doWhileChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(doWhileStatement.scopeImp, doWhileChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORReturnStatement.class){
        ORReturnStatement *returnStatement = (ORReturnStatement *)exprOrStatement;
        copy_undef_var(returnStatement.expression, chain, fromScope, destScope);
    }else if (exprOrStatementClass == ORContinueStatement.class){
        
    }else if (exprOrStatementClass == ORBreakStatement.class){
        
    }
}
@implementation ORNode(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return nil;
}

@end
@implementation ORFuncVariable (Execute)
- (id)copy{
    ORFuncVariable *var = [ORFuncVariable copyFromVar:self];
    var.pairs = self.pairs;
    return var;
}
- (MFValue *)execute:(MFScopeChain *)scope{
    return [MFValue voidValue];
}
@end
@implementation ORFuncDeclare(Execute)
- (instancetype)copy{
    ORFuncDeclare *declare = [ORFuncDeclare new];
    declare.funVar = [self.funVar copy];
    declare.returnType = self.returnType;
    return declare;
}
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray * parameters = [ORArgsStack  pop];
    [parameters enumerateObjectsUsingBlock:^(MFValue * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [scope setValue:obj withIndentifier:self.funVar.pairs[idx].var.varname];
    }];
    return nil;
}
@end
@implementation ORValueExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    switch (self.value_type) {
        case OCValueVariable:{
            MFValue *value = [scope recursiveGetValueWithIdentifier:self.value];
            if (value != nil) return value;
            Class class = NSClassFromString(self.value);
            if (class) {
                value = [MFValue valueWithClass:class];
            }else{
#if DEBUG
                if (self.value) NSLog(@"\n---------OCRunner Warning---------\n"
                                      @"Can't find object or class: %@\n"
                                      @"-----------------------------------", self.value);
#endif
                value = [MFValue voidValue];
            }
            return value;
        }
        case OCValueSelf:
        case OCValueSuper:{
            return scope.instance;
        }
        case OCValueSelector:{
            //SEL 作为参数时，在OC中，是以NSString传递的，1.0.4前的ORMethodCall只使用libffi调用objc_msgSend时，就会出现objc_retain的崩溃
            NSString *value = self.value;
            return [MFValue valueWithSEL:NSSelectorFromString(value)];
        }
        case OCValueProtocol:{
            return [MFValue valueWithObject:NSProtocolFromString(self.value)];
        }
        case OCValueDictionary:{
            NSMutableArray *exps = self.value;
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            for (NSMutableArray <ORNode *>*kv in exps) {
                ORNode *keyExp = kv.firstObject;
                ORNode *valueExp = kv.lastObject;
                id key = [keyExp execute:scope].objectValue;
                id value = [valueExp execute:scope].objectValue;
                NSAssert(key != nil, @"the key of NSDictionary can't be nil");
                NSAssert(value != nil, @"the vale of NSDictionary can't be nil");
                dict[key] = value;
            }
            return [MFValue valueWithObject:[dict copy]];
        }
        case OCValueArray:{
            NSMutableArray *exps = self.value;
            NSMutableArray *array = [NSMutableArray array];
            for (ORNode *exp in exps) {
                id value = [exp execute:scope].objectValue;
                NSAssert(value != nil, @"the vale of NSArray can't be nil");
                [array addObject:value];
            }
            return [MFValue valueWithObject:[array copy]];
        }
        case OCValueNSNumber:{
            MFValue *value = [self.value execute:scope];
            NSNumber *result = nil;
            UnaryExecuteBaseType(result, @, value);
            return [MFValue valueWithObject:result];
        }
        case OCValueString:{
            return [MFValue valueWithObject:self.value];
        }
        case OCValueCString:{
            NSString *value = self.value;
            return [MFValue valueWithCString:(char *)value.UTF8String];
        }
        case OCValueNil:{
            return [MFValue valueWithObject:nil];
        }
        case OCValueNULL:{
            return [MFValue valueWithPointer:NULL];
        }
        default:
            break;
    }
    return [MFValue valueWithObject:nil];
}
@end

@implementation ORIntegerValue (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return [MFValue valueWithLongLong:self.value];;
}
@end

@implementation ORUIntegerValue (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return [MFValue valueWithULongLong:self.value];;
}
@end

@implementation ORDoubleValue (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return [MFValue valueWithDouble:self.value];;
}
@end
@implementation ORBoolValue (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return [MFValue valueWithBOOL:self.value];;
}
@end

@implementation ORMethodCall(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    if ([self.caller isKindOfClass:[ORMethodCall class]]) {
        [(ORMethodCall *)self.caller setIsAssignedValue:self.isAssignedValue];
    }
    MFValue *variable = [self.caller execute:scope];
    if (variable.type == OCTypeStruct) {
        if ([self.names.firstObject hasPrefix:@"set"]) {
            NSString *setterName = self.names.firstObject;
            ORNode *valueExp = self.values.firstObject;
            NSString *fieldKey = [setterName substringFromIndex:3];
            NSString *first = [[fieldKey substringToIndex:1] lowercaseString];
            NSString *other = setterName.length > 1 ? [fieldKey substringFromIndex:1] : @"";
            fieldKey = [NSString stringWithFormat:@"%@%@", first, other];
            [variable setFieldWithValue:[valueExp execute:scope] forKey:fieldKey];
            return [MFValue voidValue];
        }else{
            if (self.isAssignedValue) {
                return [variable fieldNoCopyForKey:self.names.firstObject];
            }else{
                return [variable fieldForKey:self.names.firstObject];
            }
        }
    }
    id instance = variable.objectValue;
    SEL sel = NSSelectorFromString(self.selectorName);
    NSMutableArray <MFValue *>*argValues = [NSMutableArray array];
    for (ORValueExpression *exp in self.values){
        [argValues addObject:[exp execute:scope]];
    }
    // instance为nil时，依然要执行参数相关的表达式
    if ([self.caller isKindOfClass:[ORValueExpression class]]) {
        ORValueExpression *value = (ORValueExpression *)self.caller;
        if (value.value_type == OCValueSuper) {
            return invoke_sueper_values(instance, sel, argValues);
        }
    }
    if (instance == nil) {
        return [MFValue voidValue];
    }
    
    //如果在方法缓存表的中已经找到相关方法，直接调用，省去一次中间类型转换问题。优化性能，在方法递归时，调用耗时减少33%，0.15s -> 0.10s
    BOOL isClassMethod = object_isClass(instance);
    Class class = isClassMethod ? objc_getMetaClass(class_getName(instance)) : [instance class];
    MFMethodMapTableItem *map = [[MFMethodMapTable shareInstance] getMethodMapTableItemWith:class classMethod:isClassMethod sel:sel];
    if (map) {
        MFScopeChain *newScope = [MFScopeChain scopeChainWithNext:scope];
        newScope.instance = isClassMethod ? [MFValue valueWithClass:instance] : [MFValue valueWithObject:instance];
        [ORArgsStack push:argValues];
        return [map.methodImp execute:newScope];
    }
    NSMethodSignature *sig = [instance methodSignatureForSelector:sel];
    if (sig == nil) {
        NSLog(@"⚠️⚠️ Unrecognized Selector %@",self.selectorName);
        return [MFValue voidValue];
    }
    NSUInteger argCount = [sig numberOfArguments];
    void *retValuePointer = alloca([sig methodReturnLength]);
    //解决多参数调用问题
    if (argValues.count + 2 > argCount && sig != nil) {
        NSMutableArray *methodArgs = [@[[MFValue valueWithObject:instance],
                                       [MFValue valueWithSEL:sel]] mutableCopy];
        [methodArgs addObjectsFromArray:argValues];
        MFValue *result = [MFValue defaultValueWithTypeEncoding:[sig methodReturnType]];
        void *msg_send = &objc_msgSend;
        invoke_functionPointer(msg_send, methodArgs, result, argCount);
        return result;
    }else{
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        invocation.target = instance;
        invocation.selector = sel;
        for (NSUInteger i = 2; i < argCount; i++) {
            MFValue *value = argValues[i-2];
            // 基础类型转换
            value.typeEncode = [sig getArgumentTypeAtIndex:i];
            [invocation setArgument:value.pointer atIndex:i];
        }
        // func replaceIMP execute
        [invocation invoke];
        char *returnType = (char *)[sig methodReturnType];
        returnType = removeTypeEncodingPrefix(returnType);
        if (*returnType == 'v') {
            return [MFValue voidValue];
        }
        [invocation getReturnValue:retValuePointer];
    }
    const char * returnType = [sig methodReturnType];
    NSString *selectorName = NSStringFromSelector(sel);
    if ([selectorName isEqualToString:@"alloc"] || [selectorName isEqualToString:@"new"] ||
        [selectorName isEqualToString:@"copy"] || [selectorName isEqualToString:@"mutableCopy"]) {
        return [[MFValue alloc] initTypeEncode:returnType pointer:retValuePointer];
    }else{
        return [[MFValue alloc] initTypeEncode:returnType pointer:retValuePointer];
    }
    
}
@end
@implementation ORCFuncCall(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray *args = [NSMutableArray array];
    for (ORValueExpression *exp in self.expressions){
        MFValue *value = [exp execute:scope];
        NSCAssert(value != nil, @"value must be existed");
        [args addObject:value];
    }
    if ([self.caller isKindOfClass:[ORMethodCall class]] && [(ORMethodCall *)self.caller isDot]){
        // TODO: 调用block
        // make.left.equalTo(xxxx);
        MFValue *value = [(ORMethodCall *)self.caller execute:scope];
        return invoke_MFBlockValue(value, args);
    }
    //TODO: 递归函数优化, 优先查找全局函数
    id functionImp = [[ORGlobalFunctionTable shared] getFunctionNodeWithName:self.caller.value];
    if ([functionImp isKindOfClass:[ORFunctionImp class]]){
        // global function calll
        MFValue *result = nil;
        [ORArgsStack push:args];
        result = [(ORFunctionImp *)functionImp execute:scope];
        return result;
    }else if([functionImp isKindOfClass:[ORSearchedFunction class]]) {
        // 调用系统函数
        MFValue *result = nil;
        [ORArgsStack push:args];
        result = [(ORSearchedFunction *)functionImp execute:scope];
        return result;
    }else{
        MFValue *blockValue = [scope recursiveGetValueWithIdentifier:self.caller.value];
        //调用block
        if (blockValue.isBlockValue) {
            return invoke_MFBlockValue(blockValue, args);
        //调用函数指针 int (*xxx)(int a ) = &x;  xxxx();
        }else if (blockValue.funPair) {
            ORSearchedFunction *function = [ORSearchedFunction functionWithName:blockValue.funPair.var.varname];
            while (blockValue.pointerCount > 1) {
                blockValue.pointerCount--;
            }
            function.funPair = blockValue.funPair;
            function.pointer = blockValue->realBaseValue.pointerValue;
            [ORArgsStack push:args];
            return [function execute:scope];
        }
    }
    return [MFValue valueWithObject:nil];
}
@end

@implementation ORScopeImp (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope{
    //{ }
    for (id <OCExecute>statement in self.statements) {
        MFValue *result = [statement execute:scope];
        if (!result.isNormal) {
            return result;
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORFunctionImp (Execute)
- ( MFValue *)execute:(MFScopeChain *)scope{
    // C函数声明执行, 向全局作用域注册函数
    if ([ORArgsStack isEmpty]
        && self.declare.funVar.varname
        && self.declare.funVar.ptCount == 0) {
        NSString *funcName = self.declare.funVar.varname;
        if ([[ORGlobalFunctionTable shared] getFunctionNodeWithName:funcName] == nil) {
            [[ORGlobalFunctionTable shared] setFunctionNode:self WithName:funcName];
        }
        return [MFValue normalEnd];
    }
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    if (self.declare) {
        if(self.declare.isBlockDeclare){
            // xxx = ^void (int x){ }, block作为值
            MFBlock *manBlock = [[MFBlock alloc] init];
            manBlock.func = [self normalFunctionImp];
            MFScopeChain *blockScope = [MFScopeChain scopeChainWithNext:scope];
            copy_undef_var(self, [MFVarDeclareChain new], scope, blockScope);
            manBlock.outScope = blockScope;
            manBlock.retType = manBlock.func.declare.returnType;
            manBlock.paramTypes = manBlock.func.declare.funVar.pairs;
            __autoreleasing id ocBlock = [manBlock ocBlock];
            MFValue *value = [MFValue valueWithBlock:ocBlock];
            value.resultType = MFStatementResultTypeNormal;
            CFRelease((__bridge void *)ocBlock);
            return value;
        }else{
            [self.declare execute:current];
        }
    }
    ORDebugFrameStackPush(nil, self);
    MFValue *value = [self.scopeImp execute:current];
    value.resultType = MFStatementResultTypeNormal;
    ORDebugFrameStackPop();
    return value;
}
@end
@implementation ORSubscriptExpression(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *bottomValue = [self.keyExp execute:scope];
    MFValue *arrValue = [self.caller execute:scope];
    return [arrValue subscriptGetWithIndex:bottomValue];
}
@end
@implementation ORAssignExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    ORNode *resultExp;
#define SetResultExpWithBinaryOperator(type)\
    ORBinaryExpression *exp = [ORBinaryExpression new];\
    exp.left = self.value;\
    exp.right = self.expression;\
    exp.operatorType = type;\
    resultExp = exp;
    switch (self.assignType) {
        case AssignOperatorAssign:
            resultExp = self.expression;
            break;
        case AssignOperatorAssignAnd:{
            SetResultExpWithBinaryOperator(BinaryOperatorAnd);
            break;
        }
        case AssignOperatorAssignOr:{
            SetResultExpWithBinaryOperator(BinaryOperatorOr);
            break;
        }
        case AssignOperatorAssignXor:{
            SetResultExpWithBinaryOperator(BinaryOperatorXor);
            break;
        }
        case AssignOperatorAssignAdd:{
            SetResultExpWithBinaryOperator(BinaryOperatorAdd);
            break;
        }
        case AssignOperatorAssignSub:{
            SetResultExpWithBinaryOperator(BinaryOperatorSub);
            break;
        }
        case AssignOperatorAssignDiv:{
            SetResultExpWithBinaryOperator(BinaryOperatorDiv);
            break;
        }
        case AssignOperatorAssignMuti:{
            SetResultExpWithBinaryOperator(BinaryOperatorMulti);
            break;
        }
        case AssignOperatorAssignMod:{
            SetResultExpWithBinaryOperator(BinaryOperatorMod);
            break;
        }
        case AssignOperatorAssignShiftLeft:{
            SetResultExpWithBinaryOperator(BinaryOperatorShiftLeft);
            break;
        }
        case AssignOperatorAssignShiftRight:{
            SetResultExpWithBinaryOperator(BinaryOperatorShiftRight);
            break;
        }
        default:
            break;
    }
    

    if ([self.value isKindOfClass:[ORValueExpression class]]) {
        ORValueExpression *valueExp = (ORValueExpression *)self.value;
        switch (valueExp.value_type) {
            case OCValueSelf:{
                MFValue *resultValue = [resultExp execute:scope];
                scope.instance = resultValue;
                break;
            }
            case OCValueVariable:{
                MFValue *resultValue = [resultExp execute:scope];
                [scope assignWithIdentifer:(NSString *)valueExp.value value:resultValue];
                break;
            }
            default:
                break;
        }
    }else if ([self.value isKindOfClass:[ORMethodCall class]]) {
        ORMethodCall *methodCall = (ORMethodCall *)self.value;
        if (!methodCall.isDot) {
            NSCAssert(0, @"must dot grammar");
        }
        //调用对象setter方法
        NSString *setterName = methodCall.names.firstObject;
        NSString *first = [[setterName substringToIndex:1] uppercaseString];
        NSString *other = setterName.length > 1 ? [setterName substringFromIndex:1] : @"";
        setterName = [NSString stringWithFormat:@"set%@%@",first,other];
        ORMethodCall *setCaller = [ORMethodCall new];
        setCaller.caller = [(ORMethodCall *)self.value caller];
        setCaller.names = [@[setterName] mutableCopy];
        setCaller.values = [@[resultExp] mutableCopy];
        setCaller.isAssignedValue = YES;
        [setCaller execute:scope];
    }else if([self.value isKindOfClass:[ORSubscriptExpression class]]){
        MFValue *resultValue = [resultExp execute:scope];
        ORSubscriptExpression *subExp = (ORSubscriptExpression *)self.value;
        MFValue *caller = [subExp.caller execute:scope];
        MFValue *indexValue = [subExp.keyExp execute:scope];
        [caller subscriptSetValue:resultValue index:indexValue];
    }
    return [MFValue normalEnd];
}
@end
@implementation ORDeclareExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    BOOL staticVar = self.modifier & DeclarationModifierStatic;
    MFValue *(^initializeBlock)(void) = ^MFValue *{
        if (self.expression) {
            MFValue *value = [self.expression execute:scope];
            value.modifier = self.modifier;
            value.typeName = self.pair.type.name;
            value.typeEncode = self.pair.typeEncode;
            
            [value setTypeBySearchInTypeSymbolTable];
            if (value.type == OCTypeObject && [value.objectValue isMemberOfClass:[NSObject class]]) {
                NSString *reason = [NSString stringWithFormat:@"Unknown Class: %@",value.typeName];
                @throw [NSException exceptionWithName:@"OCRunner" reason:reason userInfo:nil];
            }
            if ([self.pair.var isKindOfClass:[ORFuncVariable class]]&& [(ORFuncVariable *)self.pair.var isBlock] == NO)
                value.funPair = self.pair;
            
            [scope setValue:value withIndentifier:self.pair.var.varname];
            return value;
        }else{
            MFValue *value = [MFValue defaultValueWithTypeEncoding:self.pair.typeEncode];
            value.modifier = self.modifier;
            value.typeName = self.pair.type.name;
            value.typeEncode = self.pair.typeEncode;
            
            [value setTypeBySearchInTypeSymbolTable];
            [value setDefaultValue];
            if (value.type == OCTypeObject
                && NSClassFromString(value.typeName) == nil
                && ![value.typeName isEqualToString:@"id"]) {
                NSString *reason = [NSString stringWithFormat:@"Unknown Type Identifier: %@",value.typeName];
                @throw [NSException exceptionWithName:@"OCRunner" reason:reason userInfo:nil];
            }
            
            if ([self.pair.var isKindOfClass:[ORFuncVariable class]]&& [(ORFuncVariable *)self.pair.var isBlock] == NO)
                value.funPair = self.pair;
            
            [scope setValue:value withIndentifier:self.pair.var.varname];
            return value;
        }
    };
    if (staticVar) {
        NSString *key = [NSString stringWithFormat:@"%p",(void *)self];
        MFValue *value = [[MFStaticVarTable shareInstance] getStaticVarValueWithKey:key];
        if (value) {
            [scope setValue:value withIndentifier:self.pair.var.varname];
        }else{
            MFValue *value = initializeBlock();
            [[MFStaticVarTable shareInstance] setStaticVarValue:value withKey:key];
        }
    }else{
        initializeBlock();
    }
    return [MFValue normalEnd];
}@end
@implementation ORUnaryExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *currentValue = [self.value execute:scope];
    MFValue *resultValue = [MFValue defaultValueWithTypeEncoding:currentValue.typeEncode];
    START_BOX;
    switch (self.operatorType) {
        case UnaryOperatorIncrementSuffix:{
            SuffixUnaryExecuteInt(++, currentValue);
            SuffixUnaryExecuteFloat(++, currentValue);
            break;
        }
        case UnaryOperatorDecrementSuffix:{
            SuffixUnaryExecuteInt(--, currentValue);
            SuffixUnaryExecuteFloat(--, currentValue);
            break;
        }
        case UnaryOperatorIncrementPrefix:{
            PrefixUnaryExecuteInt(++, currentValue);
            PrefixUnaryExecuteFloat(++, currentValue);
            break;
        }
        case UnaryOperatorDecrementPrefix:{
            PrefixUnaryExecuteInt(--, currentValue);
            PrefixUnaryExecuteFloat(--, currentValue);
            break;
        }
        case UnaryOperatorNot:{
            cal_result.box.boolValue = !currentValue.isSubtantial;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case UnaryOperatorSizeOf:{
            size_t result = 0;
            UnaryExecute(result, sizeof, currentValue);
            cal_result.box.longlongValue = result;
            cal_result.typeEncode = OCTypeStringLongLong;
            break;
        }
        case UnaryOperatorBiteNot:{
            PrefixUnaryExecuteInt(~, currentValue);
            break;
        }
        case UnaryOperatorNegative:{
            PrefixUnaryExecuteInt(-, currentValue);
            PrefixUnaryExecuteFloat(-, currentValue);;
            break;
        }
        case UnaryOperatorAdressPoint:{
            void *pointer = currentValue.pointer;
            resultValue.pointerCount += 1;
            resultValue.pointer = &pointer;
            return resultValue;
        }
        case UnaryOperatorAdressValue:{
            resultValue.pointerCount -= 1;
            resultValue.pointer = *(void **)currentValue.pointer;
            return resultValue;
        }
        default:
            break;
    }
    END_BOX(resultValue);
    return resultValue;
}
@end

@implementation ORBinaryExpression(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *rightValue = [self.right execute:scope];
    MFValue *leftValue = [self.left execute:scope];
    MFValue *resultValue = [MFValue defaultValueWithTypeEncoding:leftValue.typeEncode];
    START_BOX;
    switch (self.operatorType) {
        case BinaryOperatorAdd:{
            CalculateExecute(leftValue, +, rightValue);
            break;
        }
        case BinaryOperatorSub:{
            CalculateExecute(leftValue, -, rightValue);
            break;
        }
        case BinaryOperatorDiv:{
            CalculateExecute(leftValue, /, rightValue);
            break;
        }
        case BinaryOperatorMulti:{
            CalculateExecute(leftValue, *, rightValue);
            break;
        }
        case BinaryOperatorMod:{
            BinaryExecuteInt(leftValue, %, rightValue);
            break;
        }
        case BinaryOperatorShiftLeft:{
            BinaryExecuteInt(leftValue, <<, rightValue);
            break;
        }
        case BinaryOperatorShiftRight:{
            BinaryExecuteInt(leftValue, >>, rightValue);
            break;
        }
        case BinaryOperatorAnd:{
            BinaryExecuteInt(leftValue, &, rightValue);
            break;
        }
        case BinaryOperatorOr:{
            BinaryExecuteInt(leftValue, |, rightValue);
            break;
        }
        case BinaryOperatorXor:{
            BinaryExecuteInt(leftValue, ^, rightValue);
            break;
        }
        case BinaryOperatorLT:{
            LogicBinaryOperatorExecute(leftValue, <, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case BinaryOperatorGT:{
            LogicBinaryOperatorExecute(leftValue, >, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case BinaryOperatorLE:{
            LogicBinaryOperatorExecute(leftValue, <=, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case BinaryOperatorGE:{
            LogicBinaryOperatorExecute(leftValue, >=, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case BinaryOperatorNotEqual:{
            LogicBinaryOperatorExecute(leftValue, !=, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case BinaryOperatorEqual:{
            LogicBinaryOperatorExecute(leftValue, ==, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case BinaryOperatorLOGIC_AND:{
            LogicBinaryOperatorExecute(leftValue, &&, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        case BinaryOperatorLOGIC_OR:{
            LogicBinaryOperatorExecute(leftValue, ||, rightValue);
            cal_result.box.boolValue = logicResultValue;
            cal_result.typeEncode = OCTypeStringBOOL;
            break;
        }
        default:
            break;
    }
    END_BOX(resultValue);
    return resultValue;
}
@end
@implementation ORTernaryExpression(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *condition = [self.expression execute:scope];
    if (self.values.count == 1) { // condition ?: value
        if (condition.isSubtantial) {
            return condition;
        }else{
            return [self.values.lastObject execute:scope];
        }
    }else{ // condition ? value1 : value2
        if (condition.isSubtantial) {
            return [self.values.firstObject execute:scope];
        }else{
            return [self.values.lastObject execute:scope];
        }
    }
}
@end
@implementation ORIfStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray *statements = [NSMutableArray array];
    ORIfStatement *ifStatement = self;
    while (ifStatement) {
        [statements insertObject:ifStatement atIndex:0];
        ifStatement = ifStatement.last;
    }
    for (ORIfStatement *statement in statements) {
        MFValue *conditionValue = [statement.condition execute:scope];
        if (conditionValue.isSubtantial) {
            MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
            return [statement.scopeImp execute:current];
        }
    }
    if (self.condition == nil) {
        MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
        return [self.scopeImp execute:current];
    }
    return [MFValue normalEnd];
}@end
@implementation ORWhileStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    while (1) {
        if (![self.condition execute:scope].isSubtantial) {
            break;
        }
        MFValue *resultValue = [self.scopeImp execute:current];
        if (resultValue.isBreak) {
            resultValue.resultType = MFStatementResultTypeNormal;
            break;
        }else if (resultValue.isContinue){
            resultValue.resultType = MFStatementResultTypeNormal;
        }else if (resultValue.isReturn){
            return resultValue;
        }else if (resultValue.isNormal){
            
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORDoWhileStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    while (1) {
        MFValue *resultValue = [self.scopeImp execute:current];
        if (resultValue.isBreak) {
            resultValue.resultType = MFStatementResultTypeNormal;
            break;
        }else if (resultValue.isContinue){
            resultValue.resultType = MFStatementResultTypeNormal;
        }else if (resultValue.isReturn){
            return resultValue;
        }else if (resultValue.isNormal){
            
        }
        if (![self.condition execute:scope].isSubtantial) {
            break;
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORCaseStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    return [self.scopeImp execute:current];
}
@end
@implementation ORSwitchStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *value = [self.value execute:scope];
    BOOL hasMatch = NO;
    for (ORCaseStatement *statement in self.cases) {
        if (statement.value) {
            if (!hasMatch) {
                MFValue *caseValue = [statement.value execute:scope];
                LogicBinaryOperatorExecute(value, ==, caseValue);
                hasMatch = logicResultValue;
                if (!hasMatch) {
                    continue;
                }
            }
            MFValue *result = [statement execute:scope];
            if (result.isBreak) {
                result.resultType = MFStatementResultTypeNormal;
                return result;
            }else if (result.isNormal){
                continue;
            }else{
                return result;
            }
        }else{
            MFValue *result = [statement execute:scope];
            if (result.isBreak) {
                result.resultType = MFStatementResultTypeNormal;
                return value;
            }
        }
    }
    return [MFValue normalEnd];
}@end
@implementation ORForStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    for (ORNode *exp in self.varExpressions) {
        [exp execute:current];
    }
    while (1) {
        if (![self.condition execute:current].isSubtantial) {
            break;
        }
        MFValue *result = [self.scopeImp execute:current];
        if (result.isReturn) {
            return result;
        }else if (result.isBreak){
            result.resultType = MFStatementResultTypeNormal;
            return result;
        }else if (result.isContinue){
            continue;
        }
        for (ORNode *exp in self.expressions) {
            [exp execute:(MFScopeChain *)current];
        }
    }
    return [MFValue normalEnd];
}@end
@implementation ORForInStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    MFValue *arrayValue = [self.value execute:current];
    for (id element in arrayValue.objectValue) {
        //TODO: 每执行一次，在作用域中重新设置一次
        [current setValue:[MFValue valueWithObject:element] withIndentifier:self.expression.pair.var.varname];
        MFValue *result = [self.scopeImp execute:current];
        if (result.isBreak) {
            result.resultType = MFStatementResultTypeNormal;
            return result;
        }else if(result.isContinue){
            continue;
        }else if (result.isReturn){
            return result;
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORReturnStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    if (self.expression) {
        MFValue *value = [self.expression execute:scope];
        value.resultType = MFStatementResultTypeReturnValue;
        return value;
    }else{
        MFValue *value = [MFValue voidValue];
        value.resultType = MFStatementResultTypeReturnEmpty;
        return value;
    }
}
@end
@implementation ORBreakStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *value = [MFValue voidValue];
    value.resultType = MFStatementResultTypeBreak;
    return value;
}
@end
@implementation ORContinueStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *value = [MFValue voidValue];
    value.resultType = MFStatementResultTypeContinue;
    return value;
}
@end
@implementation ORPropertyDeclare(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSString *propertyName = self.var.var.varname;
    MFValue *classValue = [scope recursiveGetValueWithIdentifier:@"Class"];
    Class class = *(Class *)classValue.pointer;
    class_replaceProperty(class, [propertyName UTF8String], self.propertyAttributes, 3);
    MFPropertyMapTableItem *propItem = [[MFPropertyMapTableItem alloc] initWithClass:class property:self];
    [[MFPropertyMapTable shareInstance] addPropertyMapTableItem:propItem];
    replace_getter_method(class, self);
    replace_setter_method(class, self);
    return nil;
}
- (const objc_property_attribute_t *)propertyAttributes{
    NSValue *value = objc_getAssociatedObject(self, mf_propKey(@"propertyAttributes"));
    objc_property_attribute_t *attributes = [value pointerValue];
    if (attributes != NULL) {
        return attributes;
    }
    attributes = malloc(sizeof(objc_property_attribute_t) * 3);
    attributes[0] = self.typeAttribute;
    attributes[1] = self.memeryAttribute;
    attributes[2] = self.atomicAttribute;
    objc_setAssociatedObject(self, "propertyAttributes", [NSValue valueWithPointer:attributes], OBJC_ASSOCIATION_ASSIGN);
    return attributes;
}
-(void)dealloc{
    NSValue *value = objc_getAssociatedObject(self, mf_propKey(@"propertyAttributes"));
    objc_property_attribute_t **attributes = [value pointerValue];
    if (attributes != NULL) {
        free(attributes);
    }
}
- (objc_property_attribute_t )typeAttribute{
    objc_property_attribute_t type = {"T", self.var.typeEncode };
    return type;
}
- (objc_property_attribute_t )memeryAttribute{
    objc_property_attribute_t memAttr = {"", ""};
    switch (self.modifier & MFPropertyModifierMemMask) {
        case MFPropertyModifierMemStrong:
            memAttr.name = "&";
            break;
        case MFPropertyModifierMemWeak:
            memAttr.name = "W";
            break;
        case MFPropertyModifierMemCopy:
            memAttr.name = "C";
            break;
        default:
            break;
    }
    return memAttr;
}
- (objc_property_attribute_t )atomicAttribute{
    objc_property_attribute_t atomicAttr = {"", ""};
    switch (self.modifier & MFPropertyModifierAtomicMask) {
        case MFPropertyModifierAtomic:
            break;
        case MFPropertyModifierNonatomic:
            atomicAttr.name = "N";
            break;
        default:
            break;
    }
    return atomicAttr;
}

@end
@implementation ORMethodDeclare(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray * parameters = [ORArgsStack pop];
    [parameters enumerateObjectsUsingBlock:^(MFValue * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [scope setValue:obj withIndentifier:self.parameterNames[idx]];
    }];
    return nil;
}
@end

@implementation ORMethodImplementation(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    ORDebugFrameStackPush(scope.instance, self);
    [self.declare execute:current];
    MFValue *result = [self.scopeImp execute:current];
    result.resultType = MFStatementResultTypeNormal;
    ORDebugFrameStackPop();
    return result;
}
@end
#import <objc/runtime.h>

@implementation ORClass(Execute)
/// 执行时，根据继承顺序执行
- (nullable MFValue *)execute:(MFScopeChain *)scope{
    Class clazz = NSClassFromString(self.className);
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    if (!clazz) {
        Class superClass = NSClassFromString(self.superClassName);
        if (!superClass) {
            // 针对仅实现 @implementation xxxx @end 的类, 默认继承NSObjectt
            superClass = [NSObject class];
        }
        //添加协议
        for (NSString *name in self.protocols) {
            Protocol *protcol = NSProtocolFromString(name);
            if (protcol) {
                class_addProtocol(superClass, protcol);
            }
        }
        clazz = objc_allocateClassPair(superClass, self.className.UTF8String, 0);
        objc_registerClassPair(clazz);
    }
    // 添加Class变量到作用域
    [current setValue:[MFValue valueWithClass:clazz] withIndentifier:@"Class"];
    // 先添加属性
    for (ORPropertyDeclare *property in self.properties) {
        [property execute:current];
    }
    // 在添加方法，这样可以解决属性的懒加载不生效的问题
    for (ORMethodImplementation *method in self.methods) {
        replace_method(clazz, method, current);
    }
    return nil;
}
@end


@implementation ORStructExpressoin (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope{
    NSMutableString *typeEncode = [@"{" mutableCopy];
    NSMutableArray *keys = [NSMutableArray array];
    [typeEncode appendString:self.sturctName];
    [typeEncode appendString:@"="];
    for (ORDeclareExpression *exp in self.fields) {
        NSString *typeName = exp.pair.type.name;
        ORSymbolItem *item = [[ORTypeSymbolTable shareInstance] symbolItemForTypeName:typeName];
        if (item) {
            [typeEncode appendFormat:@"%s",item.typeEncode.UTF8String];
        }else{
            [typeEncode appendFormat:@"%s",exp.pair.typeEncode];
        }
        [keys addObject:exp.pair.var.varname];
    }
    [typeEncode appendString:@"}"];
    ORStructDeclare *declare = [ORStructDeclare structDecalre:typeEncode.UTF8String keys:keys];
    [[ORStructDeclareTable shareInstance] addStructDeclare:declare];
    
    ORTypeSpecial *special = [ORTypeSpecial specialWithType:TypeStruct name:self.sturctName];
    ORTypeVarPair *pair = [[ORTypeVarPair alloc] init];
    pair.type = special;
    // 类型表注册全局类型
    [[ORTypeSymbolTable shareInstance] addTypePair:pair forAlias:self.sturctName];
    
    return [MFValue voidValue];
}
@end

@implementation OREnumExpressoin (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope{
    ORTypeSpecial *special = [ORTypeSpecial specialWithType:self.valueType name:self.enumName];
    ORTypeVarPair *pair = [[ORTypeVarPair alloc] init];
    pair.type = special;
    const char *typeEncode = pair.typeEncode;
    MFValue *lastValue = nil;
    // 注册全局变量
    for (id exp in self.fields) {
        if ([exp isKindOfClass:[ORAssignExpression class]]) {
            ORAssignExpression *assignExp = (ORAssignExpression *)exp;
            lastValue = [assignExp.expression execute:scope];
            lastValue.typeEncode = typeEncode;
            [scope setValue:lastValue withIndentifier:[(ORValueExpression *)assignExp.value value]];
        }else if ([exp isKindOfClass:[ORValueExpression class]]){
            if (lastValue) {
                lastValue = [MFValue valueWithLongLong:lastValue.longlongValue + 1];
                lastValue.typeEncode = typeEncode;
                [scope setValue:lastValue withIndentifier:[(ORValueExpression *)exp value]];
            }else{
                lastValue = [MFValue valueWithLongLong:0];
                lastValue.typeEncode = typeEncode;
                [scope setValue:lastValue withIndentifier:[(ORValueExpression *)exp value]];
            }
        }else{
            NSCAssert(NO, @"must be ORAssignExpression and ORValueExpression");
        }
    }
    // 类型表注册全局类型
    if (self.enumName) {
        [[ORTypeSymbolTable shareInstance] addTypePair:pair forAlias:self.enumName];
    }
    return [MFValue voidValue];
}
@end

@implementation ORTypedefExpressoin (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope{
    if ([self.expression isKindOfClass:[ORTypeVarPair class]]) {
        [[ORTypeSymbolTable shareInstance] addTypePair:(ORTypeVarPair *)self.expression forAlias:self.typeNewName];
    }else if ([self.expression isKindOfClass:[ORStructExpressoin class]]){
        ORStructExpressoin *structExp = (ORStructExpressoin *)self.expression;
        [structExp execute:scope];
        ORSymbolItem *item = [[ORTypeSymbolTable shareInstance] symbolItemForTypeName:structExp.sturctName];
        [[ORTypeSymbolTable shareInstance] addSybolItem:item forAlias:self.typeNewName];
    }else if ([self.expression isKindOfClass:[OREnumExpressoin class]]){
        OREnumExpressoin *enumExp = (OREnumExpressoin *)self.expression;
        [enumExp execute:scope];
        ORTypeSpecial *special = [ORTypeSpecial specialWithType:enumExp.valueType name:self.typeNewName];
        ORTypeVarPair *pair = [[ORTypeVarPair alloc] init];
        pair.type = special;
        [[ORTypeSymbolTable shareInstance] addTypePair:pair forAlias:self.typeNewName];
    }else{
        NSCAssert(NO, @"must be ORTypeVarPair, ORStructExpressoin,  OREnumExpressoin");
    }
    return [MFValue voidValue];
}
@end


@implementation ORProtocol (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope{
    Protocol *protocol = objc_allocateProtocol(self.protcolName.UTF8String);
    for (NSString *name in self.protocols) {
        Protocol *superP = NSProtocolFromString(name);
        protocol_addProtocol(protocol, superP);
    }
    for (ORPropertyDeclare *prop in self.properties) {
        protocol_addProperty(protocol, prop.var.var.varname.UTF8String, prop.propertyAttributes, 3, NO, YES);
    }
    for (ORMethodDeclare *declare in self.methods) {
        const char *typeEncoding = declare.returnType.typeEncode;
        typeEncoding = mf_str_append(typeEncoding, "@:"); //add self and _cmd
        for (ORTypeVarPair *pair in declare.parameterTypes) {
            const char *paramTypeEncoding = pair.typeEncode;
            const char *beforeTypeEncoding = typeEncoding;
            typeEncoding = mf_str_append(typeEncoding, paramTypeEncoding);
            free((void *)beforeTypeEncoding);
        }
        protocol_addMethodDescription(protocol, NSSelectorFromString(declare.selectorName), typeEncoding, NO, !declare.isClassMethod);
    }
    objc_registerProtocol(protocol);
    return [MFValue voidValue];
}
@end
